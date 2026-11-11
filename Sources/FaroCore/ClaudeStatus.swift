import Foundation

/// Lo que Claude Code le pasa a la barra de estado (documentado): límites del plan, costo y sesión.
public struct StatusSnapshot: Sendable, Equatable {
  public struct Window: Sendable, Equatable {
    public var usedPercentage: Double
    public var resetsAt: Date?
  }
  public var sessionID: String?
  public var cwd: String?
  public var model: String?
  public var sessionCost: Double?
  public var fiveHour: Window?
  public var sevenDay: Window?
  public var capturedAt: Date?

  public var projectName: String? { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }

  public static func decode(_ data: Data) throws -> StatusSnapshot {
    guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
    let workspace = o["workspace"] as? [String: Any]
    let rate = o["rate_limits"] as? [String: Any]
    func window(_ key: String) -> Window? {
      guard let w = rate?[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
      return Window(usedPercentage: used, resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }
    return StatusSnapshot(
      sessionID: o["session_id"] as? String,
      cwd: (workspace?["project_dir"] as? String) ?? (o["cwd"] as? String),
      model: (o["model"] as? [String: Any])?["display_name"] as? String,
      sessionCost: ((o["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue,
      fiveHour: window("five_hour"),
      sevenDay: window("seven_day"),
      capturedAt: (o["_dicta_capturado"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
  }
}

/// Un evento de los hooks de Claude Code, tal como lo guarda `Faro --claude-hook`.
public struct HookEvent: Sendable, Equatable {
  public var name: String
  public var sessionID: String
  public var cwd: String?
  public var date: Date
  public var message: String?
  public var notificationType: String?

  public init(name: String, sessionID: String, cwd: String?, date: Date, message: String?, notificationType: String? = nil) {
    self.name = name
    self.sessionID = sessionID
    self.cwd = cwd
    self.date = date
    self.message = message
    self.notificationType = notificationType
  }

  public static func decode(_ line: Data) -> HookEvent? {
    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let name = o["hook_event_name"] as? String, let sid = o["session_id"] as? String
    else { return nil }
    let t = (o["_dicta_t"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
    return HookEvent(name: name, sessionID: sid, cwd: o["cwd"] as? String, date: Date(timeIntervalSince1970: t),
      message: o["message"] as? String, notificationType: o["notification_type"] as? String)
  }
}

public enum ActivityNotice: Equatable, Sendable {
  case needsYou(project: String)
  case finished(project: String, seconds: Int)
}

/// Estado de cada sesión de Claude Code a partir de los hooks: trabajando, esperándote o en reposo.
public struct ClaudeActivityBoard: Sendable {
  public enum State: Sendable, Equatable { case working, waiting, idle }
  public struct Session: Sendable, Equatable {
    public var project: String
    public var state: State
    public var workingSince: Date?
    public var lastEvent: Date
    public var cwd: String? = nil
    /// Nombre del chat (el que se ve en la app de Claude); los avisos lo usan en vez del de la carpeta.
    public var title: String? = nil

    public var displayName: String { title ?? project }
  }

  public var sessions: [String: Session] = [:]
  public init() {}

  public var workingCount: Int { sessions.values.filter { $0.state == .working }.count }
  public var waitingCount: Int { sessions.values.filter { $0.state == .waiting }.count }
  /// La sesión trabajando que empezó primero (para mostrar su tiempo en la isla).
  public var longestWorking: Session? {
    sessions.values.filter { $0.state == .working }.min { ($0.workingSince ?? .distantFuture) < ($1.workingSince ?? .distantFuture) }
  }

  /// Los hooks no traen el nombre del chat: quien lee los eventos lo busca en el registro de la sesión y lo deja aquí.
  public mutating func setTitle(_ title: String?, for sessionID: String) {
    guard let title, !title.isEmpty else { return }
    sessions[sessionID]?.title = title
    pendingTitles[sessionID] = sessions[sessionID] == nil ? title : nil
  }

  /// Nombre para una sesión que todavía no está en el tablero (llega con su primer evento).
  var pendingTitles: [String: String] = [:]

  @discardableResult
  public mutating func apply(_ e: HookEvent) -> ActivityNotice? {
    let project = e.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude"
    var s = sessions[e.sessionID] ?? Session(project: project, state: .idle, workingSince: nil, lastEvent: e.date)
    s.project = project
    if let t = pendingTitles.removeValue(forKey: e.sessionID) { s.title = t }
    s.lastEvent = e.date
    if let c = e.cwd { s.cwd = c }
    defer { if e.name != "SessionEnd" { sessions[e.sessionID] = s } }
    switch e.name {
    case "UserPromptSubmit", "PreToolUse", "PostToolUse":
      if s.state != .working {
        if s.state == .idle || s.workingSince == nil { s.workingSince = e.date }
        s.state = .working
      }
      return nil
    case "PermissionRequest":
      s.state = .waiting
      return .needsYou(project: s.displayName)
    case "Notification":
      let waitingTypes: Set<String> = ["permission_prompt", "elicitation_dialog", "agent_needs_input"]
      guard let type = e.notificationType, waitingTypes.contains(type), s.state != .waiting else { return nil }
      s.state = .waiting
      return .needsYou(project: s.displayName)
    case "Stop", "StopFailure":
      let wasBusy = s.state != .idle
      let seconds = s.workingSince.map { Int(e.date.timeIntervalSince($0).rounded()) } ?? 0
      s.state = .idle
      s.workingSince = nil
      return wasBusy ? .finished(project: s.displayName, seconds: seconds) : nil
    case "SessionEnd":
      sessions[e.sessionID] = nil
      return nil
    default:
      return nil
    }
  }

  /// Sesiones "trabajando" sin eventos en mucho tiempo (por ejemplo, Claude Code se cerró a la fuerza) pasan a reposo.
  public mutating func expire(now: Date, after seconds: TimeInterval = 1800) {
    for (id, s) in sessions where s.state != .idle && now.timeIntervalSince(s.lastEvent) > seconds {
      sessions[id]?.state = .idle
      sessions[id]?.workingSince = nil
    }
  }
}

/// Lee el final del registro de una sesión de Claude Code (`~/.claude/projects/<carpeta>/<sesión>.jsonl`) para saber
/// si sigue trabajando, aunque esa sesión no mande eventos por los hooks o lleve mucho rato en una tarea larga.
/// Solo cuentan los mensajes reales (usuario y asistente): la app de escritorio también escribe datos de control
/// (`last-prompt`, `cost-state`…) con solo abrir una sesión.
public enum TranscriptProbe {
  public struct Status: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String?
    public var lastMessageAt: Date
    /// El último mensaje es Claude cerrando su turno.
    public var finished: Bool
    /// Nombre del chat, si aparece en el tramo leído.
    public var title: String? = nil
  }

  public static func status(of url: URL, tailBytes: Int = 96 * 1024) -> Status? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
    let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    var s = status(tail: text, sessionID: url.deletingPathExtension().lastPathComponent)
    s?.title = title(tail: text)
    return s
  }

  /// Nombre del chat: Claude Code escribe una línea `custom-title` con él (y la repite a menudo, así que está en el
  /// final del registro); si se renombra, cuenta la última.
  public static func title(tail: String) -> String? {
    for line in tail.split(separator: "\n").reversed() where line.contains("\"custom-title\"") {
      guard let data = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        o["type"] as? String == "custom-title",
        let t = (o["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
      else { continue }
      return t
    }
    return nil
  }

  public static func title(of url: URL, tailBytes: Int = 96 * 1024) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
    return title(tail: String(decoding: h.readDataToEndOfFile(), as: UTF8.self))
  }

  /// Registro de una sesión por su id: `<raíz>/<carpeta del proyecto>/<sesión>.jsonl`.
  public static func file(sessionID: String, root: URL) -> URL? {
    guard !sessionID.isEmpty, !sessionID.contains("/") else { return nil }
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.lazy.map { $0.appendingPathComponent(sessionID + ".jsonl") }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  public static func status(tail: String, sessionID: String) -> Status? {
    var cwd: String?
    for line in tail.split(separator: "\n").reversed() {
      guard line.hasPrefix("{"), let data = line.data(using: .utf8),
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      if cwd == nil { cwd = o["cwd"] as? String }
      let type = o["type"] as? String
      guard type == "assistant" || type == "user", (o["isSidechain"] as? Bool) != true, (o["isMeta"] as? Bool) != true,
        let ts = (o["timestamp"] as? String).flatMap(UsageLineParser.parseDate)
      else { continue }
      let stop = (o["message"] as? [String: Any])?["stop_reason"] as? String
      let finished = type == "assistant" && (stop == "end_turn" || stop == "stop_sequence" || stop == "refusal")
      return Status(sessionID: sessionID, cwd: cwd ?? (o["cwd"] as? String), lastMessageAt: ts, finished: finished)
    }
    return nil
  }
}

extension ClaudeActivityBoard {
  /// Ajusta el tablero con lo que dice el registro de la sesión. Devuelve el aviso de "terminó" si pasó de trabajar a
  /// terminar sin que llegara el hook (sesiones sin hooks).
  @discardableResult
  public mutating func apply(_ t: TranscriptProbe.Status, now: Date, activeWindow: TimeInterval = 120) -> ActivityNotice? {
    let project = t.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? sessions[t.sessionID]?.project ?? "Claude"
    let recent = now.timeIntervalSince(t.lastMessageAt) < activeWindow
    var s = sessions[t.sessionID]
    if let title = t.title { s?.title = title }
    if !t.finished && recent {
      if s == nil {
        s = Session(project: project, state: .working, workingSince: t.lastMessageAt, lastEvent: t.lastMessageAt, cwd: t.cwd,
          title: t.title)
      } else if s!.state == .idle && t.lastMessageAt > s!.lastEvent {
        s!.state = .working
        s!.workingSince = t.lastMessageAt
      }
      // Mientras haya mensajes nuevos la sesión no "caduca", aunque la tarea dure horas.
      if t.lastMessageAt > s!.lastEvent { s!.lastEvent = t.lastMessageAt }
      sessions[t.sessionID] = s
      return nil
    }
    if t.finished, var cur = s, cur.state == .working, t.lastMessageAt >= (cur.workingSince ?? .distantPast) {
      let seconds = cur.workingSince.map { Int(t.lastMessageAt.timeIntervalSince($0).rounded()) } ?? 0
      cur.state = .idle
      cur.workingSince = nil
      cur.lastEvent = t.lastMessageAt
      sessions[t.sessionID] = cur
      if let title = t.title { cur.title = title }
      return .finished(project: cur.displayName, seconds: seconds)
    }
    return nil
  }
}
