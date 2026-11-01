import FaroCore
import Foundation

/// Lo que corre cuando Claude Code llama a Faro. Debe ser rápido y no fallar nunca: Claude Code espera su salida.
enum ClaudeBridge {
  static func readStdin() -> Data { FileHandle.standardInput.readDataToEndOfFile() }

  /// Hook: guarda el evento en `eventos.jsonl` (que la app vigila). No imprime nada: en UserPromptSubmit
  /// lo impreso se sumaría al contexto de Claude.
  static func handleHook() {
    let data = readStdin()
    guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    // Solo lo necesario; nada del prompt ni de la respuesta.
    obj = obj.filter { ["hook_event_name", "session_id", "cwd", "notification_type", "message"].contains($0.key) }
    obj["_dicta_t"] = Date().timeIntervalSince1970
    guard var line = try? JSONSerialization.data(withJSONObject: obj) else { return }
    line.append(0x0A)
    let url = ClaudeIntegration.eventsFile
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile()
      h.write(line)
      try? h.close()
    }
  }

  /// Barra de estado: guarda el JSON (límites del plan) y muestra la barra anterior del usuario o una propia.
  static func handleStatusLine() {
    let data = readStdin()
    if var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      obj["_dicta_capturado"] = Date().timeIntervalSince1970
      // Si esta vez no vinieron límites, se conservan los últimos conocidos.
      if obj["rate_limits"] == nil,
        let prevData = try? Data(contentsOf: ClaudeIntegration.statusFile),
        let prev = (try? JSONSerialization.jsonObject(with: prevData)) as? [String: Any]
      {
        obj["rate_limits"] = prev["rate_limits"]
      }
      if let out = try? JSONSerialization.data(withJSONObject: obj) {
        try? FileManager.default.createDirectory(at: ClaudeIntegration.dataDirectory, withIntermediateDirectories: true)
        try? out.write(to: ClaudeIntegration.statusFile, options: .atomic)
      }
    }
    if let previous = try? String(contentsOf: ClaudeIntegration.previousStatusLineFile, encoding: .utf8),
      !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/sh")
      p.arguments = ["-c", previous]
      let input = Pipe()
      let output = Pipe()
      p.standardInput = input
      p.standardOutput = output
      p.standardError = FileHandle.nullDevice
      if (try? p.run()) != nil {
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
        let text = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        FileHandle.standardOutput.write(text)
        return
      }
    }
    if let s = try? StatusSnapshot.decode(data) {
      var parts = [s.model ?? "Claude"]
      if let f = s.fiveHour { parts.append("5 h \(Int(f.usedPercentage)) %") }
      if let w = s.sevenDay { parts.append("semana \(Int(w.usedPercentage)) %") }
      print(parts.joined(separator: " · "))
    }
  }
}
