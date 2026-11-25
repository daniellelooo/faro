import AppKit
import ApplicationServices
import FaroCore
import Observation

/// Registra en qué se va el tiempo: cada 5 segundos mira la app al frente, la ventana, la página del navegador y la
/// sesión de Claude Code activa, y lo guarda por día en este Mac. Al empezar un día nuevo le pide a Claude el resumen
/// del anterior con lo que quedó pendiente.
@MainActor @Observable
final class ActivityTracker {
  static let interval: TimeInterval = 5
  private static let projectsKey = "proyectosTiempo"
  private static let enabledKey = "registroTiempo"
  private static let studyKey = "palabrasEstudio"

  let store = ActivityStore()
  /// Tramos de hoy, al día (la interfaz se actualiza con ellos).
  private(set) var today: [ActivitySpan] = []
  private(set) var dayKey = ActivityStore.dayKey(Date())
  /// Lo que se está haciendo ahora (nil si se está lejos del computador).
  private(set) var current: ActivityClassifier.Result?
  var projects: [TrackedProject] {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: Self.projectsKey) }
  }
  var studyWords: [String] {
    didSet { UserDefaults.standard.set(studyWords, forKey: Self.studyKey) }
  }
  var enabled: Bool {
    didSet {
      UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
      enabled ? start() : stop()
    }
  }
  /// Resumen del último día con registro antes de hoy (de donde salen los pendientes).
  private(set) var lastSummary: (day: String, summary: DaySummary)?
  private(set) var summarizing = false
  private(set) var summaryError: String?
  private(set) var week: TimeAnalyst.WeekAnalysis?
  private(set) var analyzingWeek = false
  private(set) var weekError: String?

  @ObservationIgnored weak var app: AppDelegate?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var lastSave = Date()
  @ObservationIgnored private let recorder = ActivityRecorder(maxGap: ActivityTracker.interval * 4)
  @ObservationIgnored private var rootCache: [String: String] = [:]
  @ObservationIgnored private var pageCache: (pid: pid_t, title: String?, url: URL?, pageTitle: String?)?

  static let transient: Set<String> = ["com.apple.UserNotificationCenter", "com.apple.notificationcenterui",
    "com.apple.controlcenter", "com.apple.Spotlight", "com.apple.dock", "com.apple.SecurityAgent", "com.apple.loginwindow",
    "com.apple.ScreenSaver.Engine"]

  init() {
    let d = UserDefaults.standard
    projects = d.data(forKey: Self.projectsKey).flatMap { try? JSONDecoder().decode([TrackedProject].self, from: $0) } ?? []
    enabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
    studyWords = d.stringArray(forKey: Self.studyKey) ?? ActivityClassifier.defaultStudyWords
    // Lo guardado antes de que existiera el filtro (o con listas viejas) se limpia al abrir.
    today = store.spans(day: dayKey).map { ActivityPrivacy.sanitize($0) }
    store.save(today, day: dayKey)
    loadLastSummary()
  }

  func start() {
    guard enabled, timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    timer?.tolerance = 1
    // Si un día quedó sin resumen (Faro estaba cerrado al cambiar de día), se hace ahora.
    Task { await summarizePendingDay() }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    current = nil
    save()
  }

  func save() { store.save(today, day: dayKey) }

  var classifier: ActivityClassifier {
    var c = ActivityClassifier(projects: projects, knownFolders: app?.claude.projects.projects.map(\.name) ?? [])
    c.studyWords = studyWords
    return c
  }

  // MARK: - Muestreo

  private func tick() {
    let now = Date()
    let key = ActivityStore.dayKey(now)
    if key != dayKey {
      save()
      dayKey = key
      today = []
      Task { await summarizePendingDay() }
    }
    let sample = makeSample(now)
    // Avisos y ventanas del sistema que pasan un instante al frente: siguen contando como lo que se estaba haciendo.
    if let b = sample.bundleID, Self.transient.contains(b) {
      if let last = today.indices.last, now.timeIntervalSince(today[last].end) <= Self.interval * 4 { today[last].end = now }
      return
    }
    let result = classifier.classify(sample)
    current = result
    recorder.add(result, sample: sample, to: &today)
    if now.timeIntervalSince(lastSave) > 60 {
      lastSave = now
      save()
    }
  }

  private func makeSample(_ now: Date) -> ActivitySample {
    let front = NSWorkspace.shared.frontmostApplication
    let pid = front?.processIdentifier ?? 0
    let bundle = front?.bundleIdentifier
    var title: String?
    var url: URL?
    var privateWindow = false
    if AXIsProcessTrusted(), pid > 0 {
      let appElement = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(appElement, 0.25)
      let window: AXUIElement? = AXReader.copy(appElement, kAXFocusedWindowAttribute)
      if let window {
        title = AXReader.copy(window, kAXTitleAttribute)
        privateWindow = ActivityPrivacy.isPrivateWindow(identifier: AXReader.copy(window, "AXIdentifier"))
      }
      if let bundle, ActivityClassifier.browsers.contains(bundle), let window, !privateWindow {
        // Dia y Chrome solo muestran la página a Accesibilidad si se les pide.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let page = page(pid: pid, window: window, title: title)
        url = page.url
        if let t = page.title { title = t }
      }
    }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    let session = recentClaudeSession(now)
    return ActivitySample(date: now, bundleID: bundle, app: front?.localizedName ?? "?", title: title, url: url, idle: idle,
      mediaPlaying: app?.music.current?.playing ?? false, claudeFolder: session?.folder, claudeTitle: session?.title,
      inMeeting: app?.meetings.isRecording ?? false, privateWindow: privateWindow)
  }

  /// La sesión de Claude Code donde se escribió por última vez, si fue en la última media hora. Se usa el último
  /// mensaje y no el último evento: con varias sesiones trabajando a la vez, los eventos saltan de una a otra.
  private func recentClaudeSession(_ now: Date) -> (folder: String, title: String?)? {
    guard let sessions = app?.claude.board.sessions.values,
      let s = sessions.filter({ now.timeIntervalSince($0.lastPrompt ?? .distantPast) < 1800 })
        .max(by: { ($0.lastPrompt ?? .distantPast) < ($1.lastPrompt ?? .distantPast) })
    else { return nil }
    guard let cwd = s.cwd else { return (s.project, s.title) }
    let root = rootCache[cwd] ?? ProjectsService.repositoryRoot(for: cwd)
    rootCache[cwd] = root
    return (URL(fileURLWithPath: root).lastPathComponent, s.title)
  }

  /// La dirección y el título completo de la página activa: se busca el área web en la ventana al frente. Solo se
  /// vuelve a buscar cuando cambia el título de la ventana (otra pestaña u otra página), porque recorrer el árbol cuesta.
  /// El título de la página va completo; el de la ventana de Dia viene recortado ("PERSONAL: Curso de Sw…").
  private func page(pid: pid_t, window: AXUIElement, title: String?) -> (url: URL?, title: String?) {
    if let c = pageCache, c.pid == pid, c.title == title { return (c.url, c.pageTitle) }
    var queue = [window]
    var visited = 0
    while !queue.isEmpty, visited < 600 {
      let e = queue.removeFirst()
      visited += 1
      if (AXReader.copy(e, kAXRoleAttribute) as String?) == "AXWebArea" {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, "AXURL" as CFString, &v) == .success, let v,
          let url = (v as? URL) ?? (v as? String).flatMap(URL.init(string:)) {
          let pageTitle: String? = AXReader.copy(e, kAXTitleAttribute)
          let found = (url, pageTitle?.isEmpty == false ? pageTitle : nil)
          pageCache = (pid, title, found.0, found.1)
          return found
        }
      }
      if let children: [AXUIElement] = AXReader.copy(e, kAXChildrenAttribute) { queue.append(contentsOf: children) }
    }
    // Sin área web todavía (la página está cargando o Accesibilidad recién se activó): se reintenta en el siguiente.
    return (nil, nil)
  }

  // MARK: - Totales

  var todayTotals: ActivityTotals { ActivityTotals(today) }

  func spans(day: String) -> [ActivitySpan] { day == dayKey ? today : store.spans(day: day) }

  func color(for project: String?) -> NSColor {
    guard let project, !project.isEmpty else { return .systemGray }
    if let p = projects.first(where: { $0.name == project }) { return NSColor(hex: p.color) ?? .systemGray }
    // Proyectos sin configurar: un color estable sacado del nombre.
    let palette = TrackedProject.palette
    let i = abs(project.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palette.count
    return NSColor(hex: palette[i]) ?? .systemGray
  }

  // MARK: - Resúmenes con Claude

  private func loadLastSummary() {
    for day in store.days() where day < dayKey {
      if let s = store.summary(day: day) {
        lastSummary = (day, s)
        return
      }
    }
    lastSummary = nil
  }

  /// Pendientes de días anteriores que siguen sin hacerse.
  var openPending: [DaySummary.Pending] { lastSummary?.summary.pending.filter { !$0.done } ?? [] }

  func togglePending(_ id: UUID) {
    guard var last = lastSummary, let i = last.summary.pending.firstIndex(where: { $0.id == id }) else { return }
    last.summary.pending[i].done.toggle()
    lastSummary = last
    store.saveSummary(last.summary, day: last.day)
  }

  /// Resume el día más reciente antes de hoy que tenga registro y no tenga resumen.
  func summarizePendingDay() async {
    guard let day = store.days().first(where: { $0 < dayKey }), store.summary(day: day) == nil else {
      loadLastSummary()
      return
    }
    await summarize(day: day)
  }

  func summarize(day: String) async {
    guard !summarizing, let app else { return }
    let spans = self.spans(day: day)
    guard ActivityTotals(spans).total > 300 else { return }
    summarizing = true
    summaryError = nil
    defer { summarizing = false }
    let analyst = TimeAnalyst(apiKey: app.apiKey)
    let text = TimeAnalyst.describe(day: day, spans: spans, context: context(for: day))
    do {
      let summary = try await analyst.summarizeDay(text)
      store.saveSummary(summary, day: day)
      loadLastSummary()
    } catch {
      summaryError = error.localizedDescription
    }
  }

  private func context(for day: String) -> DayContext {
    let previous = store.days().first { $0 < day }.flatMap { store.summary(day: $0) }
    let repos = (app?.claude.projects.projects ?? []).compactMap { p -> String? in
      guard let g = p.git, g.changes > 0 else { return nil }
      return "\(classifier.projectName(forFolder: p.name)) (\(p.name)): \(g.changes) archivos con cambios sin commit en la rama \(g.branch)"
    }
    let meetings = (app?.meetings.meetings ?? []).filter { ActivityStore.dayKey($0.startedAt) == day }.map { m -> String in
      var line = "- \(m.displayTitle)"
      if let s = m.summary {
        let open = s.tasks.filter { !$0.done }.map(\.description) + s.openQuestions
        if !open.isEmpty { line += ". Quedó: " + open.prefix(5).joined(separator: "; ") }
      }
      return line
    }
    let past = store.days().filter { $0 < day }.prefix(7).map { ActivityTotals(store.spans(day: $0)).work }.filter { $0 > 1800 }
    let avg = past.isEmpty ? nil : past.reduce(0, +) / Double(past.count)
    return DayContext(carriedPending: previous?.pending.filter { !$0.done } ?? [], repos: repos, meetings: meetings, averageWork: avg)
  }

  /// Últimos 7 días con registro, del más viejo al más nuevo (hoy incluido).
  func lastDays(_ n: Int = 7) -> [(day: String, totals: ActivityTotals)] {
    let cal = Calendar.current
    return (0..<n).reversed().map { offset in
      let date = cal.date(byAdding: .day, value: -offset, to: Date())!
      let key = ActivityStore.dayKey(date)
      return (key, ActivityTotals(spans(day: key)))
    }
  }

  func analyzeWeek() async {
    guard !analyzingWeek, let app else { return }
    analyzingWeek = true
    weekError = nil
    defer { analyzingWeek = false }
    var text = ""
    for (day, totals) in lastDays() where totals.total > 0 {
      text += "<dia fecha=\"\(day)\">Trabajo \(ActivityTotals.format(totals.work)), ocio \(ActivityTotals.format(totals.leisure)). "
      text += totals.byProject.filter { $0.seconds >= 300 }
        .map { "\($0.name.isEmpty ? "Sin proyecto" : $0.name) \(ActivityTotals.format($0.seconds))" }.joined(separator: ", ")
      if let s = store.summary(day: day) { text += "\nResumen: \(s.summary)" }
      text += "</dia>\n"
    }
    let names = projects.map(\.name)
    if !names.isEmpty { text += "<proyectos_importantes>\(names.joined(separator: ", "))</proyectos_importantes>\n" }
    guard !text.isEmpty else {
      weekError = "Todavía no hay días registrados."
      return
    }
    do {
      week = try await TimeAnalyst(apiKey: app.apiKey).analyzeWeek(text)
    } catch {
      weekError = error.localizedDescription
    }
  }
}

extension NSColor {
  convenience init?(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
  }
}
