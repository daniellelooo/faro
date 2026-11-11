import AppKit
import FaroCore
import Observation

/// Todo lo de Claude Code para la isla y la ventana: límites del plan, sesiones activas y valor a precio de API.
@MainActor @Observable
final class ClaudeMonitor {
  var status: StatusSnapshot?
  var board = ClaudeActivityBoard()
  var report: UsageReport?
  var computingUsage = false
  var connected = ClaudeIntegration.isConnected
  /// Límites del plan: de la cuenta (token propio), de la barra de estado o de la app de escritorio.
  var limits: PlanLimits?
  var hasLimitsToken = false
  var limitsProblem: String?
  let projects = ProjectsService()
  @ObservationIgnored var onNotice: ((ActivityNotice) -> Void)?

  private var eventsOffset: UInt64 = 0
  private var statusModified: Date?
  private var timer: Timer?
  private let cache = UsageCache()
  private var lastUsageRefresh = Date.distantPast
  private var lastTranscriptScan = Date.distantPast
  private var scanningTranscripts = false
  private var lastLimitsFetch = Date.distantPast
  private var accountLimits: PlanLimits?
  private var limitsToken: String?
  private var fetchingLimits = false
  private var desktopLimits: PlanLimits?
  private var lastDesktopCheck = Date.distantPast

  func start() {
    // Se reconstruye el tablero con las últimas horas de eventos (para no perder cuándo empezó cada sesión al
    // reiniciar Faro), sin avisos: solo los eventos nuevos avisan.
    if let h = try? FileHandle(forReadingFrom: ClaudeIntegration.eventsFile) {
      let size = (try? h.seekToEnd()) ?? 0
      try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
      let cutoff = Date().addingTimeInterval(-6 * 3600)
      for line in h.readDataToEndOfFile().split(separator: 0x0A) {
        if let e = HookEvent.decode(Data(line)), e.date > cutoff { board.apply(e) }
      }
      try? h.close()
      eventsOffset = size
      board.expire(now: Date())
    }
    limitsToken = KeychainStore.read(service: PlanUsageClient.tokenService)
    hasLimitsToken = limitsToken != nil
    tick()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private func tick() {
    readEvents()
    readStatus()
    if Date().timeIntervalSince(lastTranscriptScan) > 3 { scanTranscripts() }
    board.expire(now: Date())
    if Date().timeIntervalSince(lastUsageRefresh) > 60 { refreshUsage() }
    if limitsToken != nil, Date().timeIntervalSince(lastLimitsFetch) > (PlanUsageClient.usageEndpointForbidden ? 300 : 180) { fetchLimits() }
    if Date().timeIntervalSince(lastDesktopCheck) > 60 {
      lastDesktopCheck = Date()
      desktopLimits = DesktopUsageHistory.latest()
    }
    chooseLimits()
  }

  /// Se queda con la lectura más fresca; una de más de 15 minutos ya no se muestra.
  private func chooseLimits() {
    let now = Date()
    var candidates: [PlanLimits] = []
    if let a = accountLimits { candidates.append(a) }
    if let s = status, let l = PlanLimits(snapshot: s, now: now) { candidates.append(l) }
    if let d = desktopLimits { candidates.append(d) }
    let best = candidates.filter { now.timeIntervalSince($0.fetchedAt) < 15 * 60 }.max { $0.fetchedAt < $1.fetchedAt }
    if best != limits { limits = best }
  }

  func fetchLimits() {
    guard let token = limitsToken, !fetchingLimits else { return }
    fetchingLimits = true
    lastLimitsFetch = Date()
    Task {
      do {
        accountLimits = try await PlanUsageClient.fetch(token: token)
        limitsProblem = nil
      } catch PlanUsageClient.Failure.unauthorized {
        limitsProblem = "El token ya no es válido. Genera otro con claude setup-token."
      } catch PlanUsageClient.Failure.forbidden {
        limitsProblem = "Ese token no tiene permiso para leer el uso de la cuenta."
      } catch {
        limitsProblem = "No se pudo consultar el uso (\(error.localizedDescription))."
      }
      fetchingLimits = false
      chooseLimits()
    }
  }

  /// Prueba el token contra la cuenta y solo lo guarda si funciona.
  func saveLimitsToken(_ raw: String) async -> String? {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.hasPrefix("sk-ant-"), !token.contains(" ") else { return "Eso no parece un token de Claude (empieza por sk-ant-)." }
    do {
      let l = try await PlanUsageClient.fetch(token: token)
      guard KeychainStore.write(service: PlanUsageClient.tokenService, value: token) else { return "No se pudo guardar en el Llavero." }
      limitsToken = token
      hasLimitsToken = true
      accountLimits = l
      limitsProblem = nil
      lastLimitsFetch = Date()
      chooseLimits()
      return nil
    } catch PlanUsageClient.Failure.unauthorized {
      return "Claude rechazó el token. Copia completo el que imprime claude setup-token."
    } catch PlanUsageClient.Failure.forbidden {
      return "El token es válido pero no puede leer el uso de la cuenta."
    } catch {
      return "No se pudo comprobar: \(error.localizedDescription)"
    }
  }

  func removeLimitsToken() {
    KeychainStore.delete(service: PlanUsageClient.tokenService)
    limitsToken = nil
    hasLimitsToken = false
    accountLimits = nil
    limitsProblem = nil
    chooseLimits()
  }

  nonisolated static let transcriptsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

  private func readEvents() {
    let url = ClaudeIntegration.eventsFile
    guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 else { return }
    if size < eventsOffset { eventsOffset = 0 }
    guard size > eventsOffset, let h = try? FileHandle(forReadingFrom: url) else { return }
    try? h.seek(toOffset: eventsOffset)
    let data = h.readDataToEndOfFile()
    try? h.close()
    guard let last = data.lastIndex(of: 0x0A) else { return }
    eventsOffset += UInt64(data.distance(from: data.startIndex, to: last) + 1)
    for line in data[data.startIndex...last].split(separator: 0x0A) {
      guard let e = HookEvent.decode(Data(line)) else { continue }
      // Solo los eventos que avisan necesitan el nombre del chat; buscarlo es leer el final de su registro.
      if ["Stop", "StopFailure", "PermissionRequest", "Notification"].contains(e.name),
        let f = TranscriptProbe.file(sessionID: e.sessionID, root: Self.transcriptsRoot) {
        board.setTitle(TranscriptProbe.title(of: f), for: e.sessionID)
      }
      if let notice = board.apply(e) { onNotice?(notice) }
    }
  }

  private func readStatus() {
    let url = ClaudeIntegration.statusFile
    guard let mod = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, mod != statusModified,
      let data = try? Data(contentsOf: url), let s = try? StatusSnapshot.decode(data)
    else { return }
    statusModified = mod
    status = s
  }

  /// Sesiones vistas por su registro: las que no mandan hooks y las tareas largas sin eventos intermedios.
  private func scanTranscripts() {
    guard !scanningTranscripts else { return }
    scanningTranscripts = true
    lastTranscriptScan = Date()
    Task.detached(priority: .utility) {
      let root = ClaudeMonitor.transcriptsRoot
      let cutoff = Date().addingTimeInterval(-600)
      var found: [TranscriptProbe.Status] = []
      let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
      for dir in dirs {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.pathExtension == "jsonl" {
          guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > cutoff,
            let st = TranscriptProbe.status(of: f)
          else { continue }
          found.append(st)
        }
      }
      let statuses = found
      await MainActor.run {
        let now = Date()
        for st in statuses {
          if let notice = self.board.apply(st, now: now) { self.onNotice?(notice) }
        }
        self.scanningTranscripts = false
      }
    }
  }

  func refreshUsage() {
    guard !computingUsage else { return }
    lastUsageRefresh = Date()
    computingUsage = true
    let cache = self.cache
    Task.detached(priority: .utility) {
      let r = cache.refresh()
      await MainActor.run {
        self.report = r
        self.projects.update(from: r)
        self.computingUsage = false
      }
    }
  }

  func connect() throws {
    _ = try ClaudeIntegration.connect(executable: Bundle.main.executablePath ?? "/Applications/Faro.app/Contents/MacOS/Faro")
    connected = ClaudeIntegration.isConnected
  }

  func disconnect() throws {
    try ClaudeIntegration.disconnect()
    connected = ClaudeIntegration.isConnected
  }

  // Valores para mostrar
  var costToday: Double { report?.cost(since: Date()) ?? 0 }
  var costWeek: Double { report?.cost(since: Date().addingTimeInterval(-6 * 86400)) ?? 0 }
  var costMonth: Double {
    let cal = Calendar.current
    return report?.cost(since: cal.date(from: cal.dateComponents([.year, .month], from: Date()))!) ?? 0
  }
}
