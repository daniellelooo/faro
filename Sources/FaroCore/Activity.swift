import Foundation

/// Trabajo u ocio. El tiempo fuera del computador no se registra.
public enum ActivityKind: String, Codable, Sendable {
  case work, leisure
}

/// Un tramo continuo haciendo lo mismo: misma app, misma ventana, mismo proyecto.
public struct ActivitySpan: Codable, Sendable, Equatable, Identifiable {
  public var start: Date
  public var end: Date
  public var bundleID: String?
  public var app: String
  /// Título de la ventana (en un navegador, el de la pestaña).
  public var title: String?
  /// Dominio de la página, en un navegador.
  public var host: String?
  public var project: String?
  /// Nombre del chat de Claude Code con el que se trabajaba, si se sabe.
  public var detail: String?
  public var kind: ActivityKind

  public var id: Date { start }
  public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

  public init(start: Date, end: Date, bundleID: String?, app: String, title: String?, host: String?, project: String?,
    detail: String? = nil, kind: ActivityKind) {
    self.start = start
    self.end = end
    self.bundleID = bundleID
    self.app = app
    self.title = title
    self.host = host
    self.project = project
    self.detail = detail
    self.kind = kind
  }

  /// Mismo tramo si solo cambió la hora.
  func continues(_ other: ActivitySpan) -> Bool {
    bundleID == other.bundleID && app == other.app && title == other.title && host == other.host
      && project == other.project && detail == other.detail && kind == other.kind
  }
}

/// Un proyecto definido por la persona: su nombre, su color y las palabras que lo delatan
/// (nombre de la carpeta del repositorio, dominio, algo del título de la ventana).
public struct TrackedProject: Codable, Sendable, Equatable, Identifiable, Hashable {
  public var id: UUID
  public var name: String
  public var color: String
  public var keywords: [String]

  public init(id: UUID = UUID(), name: String, color: String, keywords: [String]) {
    self.id = id
    self.name = name
    self.color = color
    self.keywords = keywords
  }

  public static let palette = ["#3B82F6", "#F59E0B", "#8B5CF6", "#10B981", "#EF4444", "#06B6D4", "#EC4899", "#84CC16"]
}

/// Lo que se ve en un instante: la app al frente y, si hay, la sesión de Claude Code activa.
public struct ActivitySample: Sendable {
  public var date: Date
  public var bundleID: String?
  public var app: String
  public var title: String?
  public var url: URL?
  /// Segundos sin tocar teclado ni ratón.
  public var idle: TimeInterval
  /// Suena algo (video o música) en alguna app.
  public var mediaPlaying: Bool
  /// Carpeta del proyecto de la sesión de Claude Code más reciente (si hubo actividad hace poco).
  public var claudeFolder: String?
  public var claudeTitle: String?
  /// Hay una reunión grabándose.
  public var inMeeting: Bool

  public init(date: Date, bundleID: String?, app: String, title: String?, url: URL?, idle: TimeInterval,
    mediaPlaying: Bool = false, claudeFolder: String? = nil, claudeTitle: String? = nil, inMeeting: Bool = false) {
    self.date = date
    self.bundleID = bundleID
    self.app = app
    self.title = title
    self.url = url
    self.idle = idle
    self.mediaPlaying = mediaPlaying
    self.claudeFolder = claudeFolder
    self.claudeTitle = claudeTitle
    self.inMeeting = inMeeting
  }
}

/// Decide si un instante es trabajo, ocio o nada (lejos del computador), y de qué proyecto.
public struct ActivityClassifier: Sendable {
  public var projects: [TrackedProject]
  /// Carpetas de proyectos conocidos (los de Claude Code), para reconocerlos sin configurar nada.
  public var knownFolders: [String]
  /// Sin tocar nada durante más de esto ya no se cuenta, salvo que esté sonando un video al frente o haya reunión.
  public var idleLimit: TimeInterval = 180

  /// Ocio: ver series y películas, videos y juegos. Todo lo demás en el computador cuenta como trabajo.
  public static let leisureApps = ["stremio", "netflix", "tv", "steam", "minecraft", "iina", "vlc", "infuse", "plex",
    "disney+", "prime video"]
  public static let leisureHosts = ["youtube.com", "youtu.be", "netflix.com", "twitch.tv", "primevideo.com", "disneyplus.com",
    "max.com", "hbomax.com", "crunchyroll.com", "stremio.com"]
  /// Apps donde se programa: con ellas al frente, el proyecto de Claude Code activo es el que se está trabajando.
  public static let codingApps = ["com.anthropic.claudefordesktop", "com.apple.Terminal", "com.googlecode.iterm2",
    "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    "dev.zed.Zed", "com.apple.dt.Xcode", "com.exafunction.windsurf"]

  public init(projects: [TrackedProject], knownFolders: [String] = []) {
    self.projects = projects
    self.knownFolders = knownFolders
  }

  public struct Result: Sendable, Equatable {
    public var kind: ActivityKind
    public var project: String?
    public var detail: String?
  }

  public func classify(_ s: ActivitySample) -> Result? {
    let leisure = isLeisure(s)
    if s.inMeeting { return Result(kind: .work, project: project(for: s) ?? "Reuniones", detail: nil) }
    if s.idle > idleLimit {
      // Un video al frente sigue contando aunque no se toque nada; el resto es estar lejos.
      guard leisure, s.mediaPlaying else { return nil }
    }
    if leisure { return Result(kind: .leisure, project: nil, detail: nil) }
    let coding = s.bundleID.map(Self.codingApps.contains) ?? false
    return Result(kind: .work, project: project(for: s), detail: coding ? s.claudeTitle : nil)
  }

  public func isLeisure(_ s: ActivitySample) -> Bool {
    let app = s.app.lowercased()
    if Self.leisureApps.contains(where: { app == $0 || app.hasPrefix($0 + " ") }) || app.contains("stremio") { return true }
    if let host = s.url?.host?.lowercased() {
      return Self.leisureHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    return false
  }

  /// El proyecto se busca en este orden: la página (dominio y ruta), el título de la ventana y, si al frente hay una app
  /// de programar, la carpeta de la sesión de Claude Code. En cada uno, primero los proyectos configurados.
  public func project(for s: ActivitySample) -> String? {
    let coding = s.bundleID.map(Self.codingApps.contains) ?? false
    var texts: [String] = []
    if let url = s.url { texts.append((url.host ?? "") + url.path) }
    if let t = s.title { texts.append(t) }
    if coding, let f = s.claudeFolder { texts.append(f) }
    for text in texts {
      let low = text.lowercased()
      if let p = projects.first(where: { p in p.keywords.contains { k in matches(k, in: low) } }) { return p.name }
      if let f = knownFolders.first(where: { matches($0, in: low) }) { return projectName(forFolder: f) }
    }
    return nil
  }

  /// La carpeta de un repositorio, con el nombre del proyecto configurado que la reclama si hay uno.
  public func projectName(forFolder folder: String) -> String {
    let low = folder.lowercased()
    return projects.first(where: { p in p.keywords.contains { matches($0, in: low) } })?.name ?? folder
  }

  /// Palabra completa (o separada por guiones, puntos, barras): "faro" no debe encontrarse en "faroles".
  func matches(_ keyword: String, in text: String) -> Bool {
    let k = keyword.lowercased().trimmingCharacters(in: .whitespaces)
    guard k.count >= 2 else { return false }
    var search = text.startIndex..<text.endIndex
    while let r = text.range(of: k, range: search) {
      let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
      let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
      let isBoundary = { (c: Character?) in c.map { !$0.isLetter && !$0.isNumber } ?? true }
      if isBoundary(before) && isBoundary(after) { return true }
      search = r.upperBound..<text.endIndex
    }
    return false
  }
}

/// Totales de un conjunto de tramos.
public struct ActivityTotals: Sendable, Equatable {
  public var work: TimeInterval = 0
  public var leisure: TimeInterval = 0
  /// Tiempo de trabajo por proyecto ("" = sin proyecto), de mayor a menor.
  public var byProject: [(name: String, seconds: TimeInterval)] = []
  public var byApp: [(name: String, bundleID: String?, seconds: TimeInterval)] = []
  public var first: Date?
  public var last: Date?

  public static func == (a: ActivityTotals, b: ActivityTotals) -> Bool {
    a.work == b.work && a.leisure == b.leisure && a.byProject.map(\.name) == b.byProject.map(\.name)
      && a.byProject.map(\.seconds) == b.byProject.map(\.seconds) && a.first == b.first && a.last == b.last
  }

  public init(_ spans: [ActivitySpan]) {
    var projects: [String: TimeInterval] = [:]
    var apps: [String: (String?, TimeInterval)] = [:]
    for s in spans {
      if s.kind == .work {
        work += s.duration
        projects[s.project ?? "", default: 0] += s.duration
      } else {
        leisure += s.duration
      }
      let name = ActivityRecorder.clean(s.app) ?? s.app
      let a = apps[name] ?? (s.bundleID, 0)
      apps[name] = (a.0, a.1 + s.duration)
    }
    byProject = projects.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    byApp = apps.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.seconds > $1.seconds }
    first = spans.map(\.start).min()
    last = spans.map(\.end).max()
  }

  public var total: TimeInterval { work + leisure }

  /// "4 h 12 min", "35 min", "0 min".
  public static func format(_ seconds: TimeInterval, short: Bool = false) -> String {
    let m = Int(seconds / 60)
    if short { return String(format: "%d:%02d", m / 60, m % 60) }
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
  }
}

/// Lo más visto dentro de un proyecto: los títulos de ventana (o chats de Claude) en los que más tiempo se pasó.
public enum ActivityDetail {
  public static func topItems(_ spans: [ActivitySpan], limit: Int = 6) -> [(text: String, seconds: TimeInterval)] {
    var t: [String: TimeInterval] = [:]
    for s in spans {
      let label = s.detail ?? cleanTitle(s.title, app: s.app) ?? s.host ?? s.app
      t[label, default: 0] += s.duration
    }
    let items: [(text: String, seconds: TimeInterval)] = t.map { (text: $0.key, seconds: $0.value) }
    return Array(items.sorted { $0.seconds > $1.seconds }.prefix(limit))
  }

  /// Quita del título el nombre de la app o del navegador que algunos agregan al final.
  static func cleanTitle(_ title: String?, app: String) -> String? {
    guard var t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    for sep in [" - ", " — ", " – "] where t.hasSuffix(sep + app) { t = String(t.dropLast(sep.count + app.count)) }
    return t == app ? nil : t
  }
}

/// Registro del tiempo en disco: un archivo JSON por día en `Application Support/Faro/tiempo`.
public final class ActivityStore: @unchecked Sendable {
  public static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Faro/tiempo")
  }

  public let root: URL
  private let lock = NSLock()

  public init(root: URL = ActivityStore.defaultRoot) {
    self.root = root
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  func url(_ day: String) -> URL { root.appendingPathComponent(day + ".json") }
  func summaryURL(_ day: String) -> URL { root.appendingPathComponent(day + "-resumen.json") }

  public func spans(on date: Date) -> [ActivitySpan] { spans(day: Self.dayKey(date)) }

  public func spans(day: String) -> [ActivitySpan] {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: url(day)) else { return [] }
    return (try? JSONDecoder.iso.decode([ActivitySpan].self, from: data)) ?? []
  }

  public func save(_ spans: [ActivitySpan], day: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? JSONEncoder.iso.encode(spans) else { return }
    try? data.write(to: url(day), options: .atomic)
  }

  public func summary(day: String) -> DaySummary? {
    guard let data = try? Data(contentsOf: summaryURL(day)) else { return nil }
    return try? JSONDecoder.iso.decode(DaySummary.self, from: data)
  }

  public func saveSummary(_ s: DaySummary, day: String) {
    guard let data = try? JSONEncoder.iso.encode(s) else { return }
    try? data.write(to: summaryURL(day), options: .atomic)
  }

  /// Días con registro, del más reciente al más viejo.
  public func days() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return files.filter { $0.hasSuffix(".json") && !$0.contains("resumen") }.map { String($0.dropLast(5)) }.sorted(by: >)
  }
}

extension ActivityRecorder {
  /// Sin marcas invisibles de dirección de texto (WhatsApp antepone una al nombre) ni espacios sobrantes.
  public static func clean(_ text: String?) -> String? {
    guard let text else { return nil }
    let invisible: Set<Unicode.Scalar> = ["\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{200B}", "\u{FEFF}"]
    let t = String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisible.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}

/// Agrega instantes a los tramos del día: extiende el último si sigue igual o abre uno nuevo.
public struct ActivityRecorder: Sendable {
  /// Más de esto entre dos instantes se considera un corte (Mac dormido, Faro cerrado).
  public var maxGap: TimeInterval

  public init(maxGap: TimeInterval = 20) { self.maxGap = maxGap }

  public func add(_ result: ActivityClassifier.Result?, sample s: ActivitySample, to spans: inout [ActivitySpan]) {
    guard let result else { return }
    let title = Self.clean(s.title).map { String($0.prefix(160)) }
    var span = ActivityPrivacy.sanitize(ActivitySpan(start: s.date, end: s.date, bundleID: s.bundleID,
      app: Self.clean(s.app) ?? s.app, title: title, host: s.url?.host, project: result.project, detail: result.detail,
      kind: result.kind), path: s.url?.path)
    if let last = spans.last, s.date.timeIntervalSince(last.end) <= maxGap {
      if last.continues(span) {
        spans[spans.count - 1].end = s.date
        return
      }
      // El tramo nuevo empieza donde terminó el anterior, sin huecos de muestreo.
      span.start = last.end
      span.end = s.date
    }
    spans.append(span)
  }
}

/// Lo que nunca se guarda: en apps de mensajes, correo, contraseñas o banca, y en sitios equivalentes, solo queda el
/// nombre de la app o el dominio (nunca el título, que trae nombres de contactos, asuntos o saldos). De las ventanas
/// privadas o de incógnito no queda ni el dominio. Se aplica antes de escribir a disco, así que tampoco llega a Claude.
public enum ActivityPrivacy {
  public static let privateApps: Set<String> = [
    "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram", "org.telegram.desktop",
    "org.whispersystems.signal-desktop", "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
    "com.hnc.Discord", "com.facebook.archon", "com.apple.FaceTime", "com.apple.mail", "com.microsoft.Outlook",
    "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac", "com.apple.AddressBook", "com.apple.Photos",
    "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.bitwarden.desktop",
    "com.apple.Notes", "com.apple.iCal", "com.apple.reminders", "com.apple.Health",
  ]
  /// Palabras en el nombre de la app, para versiones con otro identificador.
  static let privateAppWords = ["whatsapp", "telegram", "signal", "messenger", "mensajes", "messages", "teams", "slack",
    "discord", "mail", "correo", "outlook", "1password", "bitwarden", "contraseñas", "passwords"]
  public static let privateHosts = [
    "web.whatsapp.com", "whatsapp.com", "web.telegram.org", "messenger.com", "discord.com", "app.slack.com",
    "teams.microsoft.com", "teams.live.com", "mail.google.com", "outlook.live.com", "outlook.office.com",
    "outlook.office365.com", "mail.yahoo.com", "icloud.com", "contacts.google.com", "photos.google.com",
    "drive.google.com", "paypal.com", "nequi.com.co", "daviplata.com", "1password.com", "bitwarden.com",
  ]
  /// Palabras en el dominio (bancos y similares).
  static let privateHostWords = ["bank", "banco", "bancolombia", "davivienda", "bbva", "scotiabank", "itau", "nubank",
    "lulo", "colpatria", "avvillas", "occidente", "popular", "falabella", "nequi", "daviplata", "binance", "coinbase"]
  /// Rutas privadas dentro de sitios que no lo son (los mensajes directos de una red social).
  static let privatePaths = [("instagram.com", "/direct"), ("facebook.com", "/messages"), ("x.com", "/messages"),
    ("linkedin.com", "/messaging")]
  /// Así marcan los navegadores sus ventanas privadas en el título.
  static let incognitoMarks = ["incognito", "incógnito", "private browsing", "navegación privada", "ventana privada",
    "inprivate", "modo privado", "private window"]

  public static func isPrivateApp(bundleID: String?, name: String) -> Bool {
    if let b = bundleID, privateApps.contains(b) { return true }
    let n = name.lowercased()
    return privateAppWords.contains { n == $0 || n.hasPrefix($0 + " ") || n.hasSuffix(" " + $0) }
  }

  public static func isPrivate(host: String?, path: String? = nil) -> Bool {
    guard let h = host?.lowercased() else { return false }
    let match = { (d: String) in h == d || h.hasSuffix("." + d) }
    if privateHosts.contains(where: match) { return true }
    let labels = h.split(separator: ".").map(String.init)
    // Las palabras largas pueden ir dentro del dominio ("transaccionesbancolombia"); las cortas, solo al principio.
    if labels.contains(where: { l in privateHostWords.contains { $0.count >= 5 ? l.contains($0) : l.hasPrefix($0) } }) { return true }
    if let path { return privatePaths.contains { match($0.0) && path.hasPrefix($0.1) } }
    return false
  }

  public static func isIncognito(title: String?) -> Bool {
    guard let t = title?.lowercased() else { return false }
    return incognitoMarks.contains { t.contains($0) }
  }

  /// El tramo sin lo que no debe quedar registrado.
  public static func sanitize(_ span: ActivitySpan, path: String? = nil) -> ActivitySpan {
    var s = span
    if isIncognito(title: s.title) {
      s.title = "Ventana privada"
      s.host = nil
    } else if isPrivateApp(bundleID: s.bundleID, name: s.app) || isPrivate(host: s.host, path: path) {
      s.title = nil
    }
    return s
  }
}
