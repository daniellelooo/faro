import Foundation

/// Conecta Faro con Claude Code agregando una barra de estado y hooks a `~/.claude/settings.json`,
/// sin borrar lo que ya había: la barra de estado anterior se sigue ejecutando a través de la de Faro.
public enum ClaudeIntegration {
  public static let hookFlag = "--claude-hook"
  public static let statusFlag = "--claude-statusline"
  public static let events = ["UserPromptSubmit", "Stop", "StopFailure", "Notification", "PermissionRequest", "SessionEnd"]

  public static var settingsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }
  public static var dataDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Faro/claude")
  }
  public static var eventsFile: URL { dataDirectory.appendingPathComponent("eventos.jsonl") }
  public static var statusFile: URL { dataDirectory.appendingPathComponent("barra-de-estado.json") }
  public static var previousStatusLineFile: URL { dataDirectory.appendingPathComponent("barra-de-estado-anterior.txt") }

  static func quoted(_ path: String) -> String { "\"\(path)\"" }

  public static func isOurs(_ command: String?) -> Bool {
    guard let command else { return false }
    return command.contains(hookFlag) || command.contains(statusFlag)
  }

  public static func isInstalled(_ settings: [String: Any]) -> Bool {
    if isOurs((settings["statusLine"] as? [String: Any])?["command"] as? String) { return true }
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    return hooks.values.contains { groups in
      (groups as? [[String: Any]] ?? []).contains { g in
        (g["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"] as? String) }
      }
    }
  }

  public static func install(into settings: [String: Any], executable: String) -> (settings: [String: Any], previousStatusLine: String?) {
    var s = settings
    var previous: String?
    let existing = (s["statusLine"] as? [String: Any])?["command"] as? String
    if !isOurs(existing) { previous = existing }
    s["statusLine"] = ["type": "command", "command": "\(quoted(executable)) \(statusFlag)", "padding": 0]
    var hooks = s["hooks"] as? [String: Any] ?? [:]
    let ourHook: [String: Any] = ["type": "command", "command": "\(quoted(executable)) \(hookFlag)", "timeout": 5]
    for event in events {
      var groups = hooks[event] as? [[String: Any]] ?? []
      let present = groups.contains { g in (g["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"] as? String) } }
      if !present { groups.append(["hooks": [ourHook]]) }
      hooks[event] = groups
    }
    s["hooks"] = hooks
    return (s, previous)
  }

  public static func uninstall(from settings: [String: Any], previousStatusLine: String?) -> [String: Any] {
    var s = settings
    if isOurs((s["statusLine"] as? [String: Any])?["command"] as? String) {
      if let previousStatusLine, !previousStatusLine.isEmpty {
        s["statusLine"] = ["type": "command", "command": previousStatusLine]
      } else {
        s["statusLine"] = nil
      }
    }
    var hooks = s["hooks"] as? [String: Any] ?? [:]
    for (event, value) in hooks {
      var groups = value as? [[String: Any]] ?? []
      groups = groups.compactMap { g in
        var g = g
        let kept = (g["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String) }
        if kept.isEmpty { return nil }
        g["hooks"] = kept
        return g
      }
      hooks[event] = groups.isEmpty ? nil : groups
    }
    s["hooks"] = hooks.isEmpty ? nil : hooks
    return s
  }

  // MARK: Archivos

  public static func readSettings() -> [String: Any] {
    guard let data = try? Data(contentsOf: settingsURL),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
  }

  public static func writeSettings(_ settings: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: settingsURL, options: .atomic)
  }

  /// Instala en el `settings.json` real, con copia de respaldo con fecha.
  public static func connect(executable: String) throws -> URL? {
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    var backup: URL?
    if FileManager.default.fileExists(atPath: settingsURL.path) {
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
      let b = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.respaldo-dicta-\(stamp)")
      try FileManager.default.copyItem(at: settingsURL, to: b)
      backup = b
    }
    let result = install(into: readSettings(), executable: executable)
    if let previous = result.previousStatusLine {
      try previous.write(to: previousStatusLineFile, atomically: true, encoding: .utf8)
    }
    try writeSettings(result.settings)
    return backup
  }

  public static func disconnect() throws {
    let previous = try? String(contentsOf: previousStatusLineFile, encoding: .utf8)
    try writeSettings(uninstall(from: readSettings(), previousStatusLine: previous))
  }

  public static var isConnected: Bool { isInstalled(readSettings()) }

  /// Si la app cambió de lugar o de nombre (Dicta → Faro), los comandos de Claude Code apuntan al ejecutable viejo:
  /// se reescriben al actual. Devuelve true si cambió algo.
  @discardableResult
  public static func repairExecutablePath(_ executable: String) -> Bool {
    let settings = readSettings()
    guard isInstalled(settings) else { return false }
    func fix(_ command: String) -> String {
      for flag in [hookFlag, statusFlag] where command.contains(flag) {
        return "\(quoted(executable)) \(flag)"
      }
      return command
    }
    var s = settings
    var changed = false
    if var status = s["statusLine"] as? [String: Any], let c = status["command"] as? String, isOurs(c), fix(c) != c {
      status["command"] = fix(c)
      s["statusLine"] = status
      changed = true
    }
    var hooks = s["hooks"] as? [String: Any] ?? [:]
    for (event, value) in hooks {
      let groups = (value as? [[String: Any]] ?? []).map { g -> [String: Any] in
        var g = g
        g["hooks"] = (g["hooks"] as? [[String: Any]] ?? []).map { h -> [String: Any] in
          var h = h
          if let c = h["command"] as? String, isOurs(c), fix(c) != c {
            h["command"] = fix(c)
            changed = true
          }
          return h
        }
        return g
      }
      hooks[event] = groups
    }
    guard changed else { return false }
    s["hooks"] = hooks
    try? writeSettings(s)
    return true
  }
}
