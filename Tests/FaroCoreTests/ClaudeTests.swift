import Foundation
import Testing
@testable import FaroCore

@Suite struct ClaudeUsageTests {
  func line(id: String, model: String, input: Int, output: Int, read: Int, write5m: Int, write1h: Int, ts: String, speed: String = "standard") -> String {
    """
    {"type":"assistant","timestamp":"\(ts)","requestId":"req_\(id)","message":{"id":"msg_\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(read),"cache_creation_input_tokens":\(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)},"speed":"\(speed)"}}}
    """
  }

  @Test func costoDeUnMensajeDeOpus55() {
    // Opus 5.5: $4 entrada, $20 salida por millón; caché leída 0,1x; escritura 5 min 1,25x; 1 hora 2x.
    let u = TokenUsage(input: 1_000_000, output: 100_000, cacheRead: 1_000_000, cacheWrite5m: 100_000, cacheWrite1h: 100_000)
    let cost = ModelPricing.cost(model: "claude-opus-5-5", usage: u, fast: false)
    let expectedCost: Double = 4 + 2 + 0.4 + 0.5 + 0.8
    #expect(abs(cost - expectedCost) < 0.0001)
    #expect(abs(ModelPricing.cost(model: "claude-opus-5-5", usage: u, fast: true) - 2 * cost) < 0.0001)
  }

  @Test func elLectorSumaPorModeloSinContarDosVecesElMismoMensaje() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)/proyecto")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a: String = line(id: "a", model: "claude-opus-5-5", input: 1000, output: 500, read: 0, write5m: 0, write1h: 0, ts: "2026-10-22T10:00:00Z")
    let b: String = line(id: "b", model: "claude-haiku-5-5", input: 2000, output: 1000, read: 0, write5m: 0, write1h: 0, ts: "2026-10-22T11:00:00Z")
    let user: String = #"{"type":"user","message":{"content":"hola"}}"#
    let lines: [String] = [a, a, b, user, "linea rota {"]
    let jsonl: String = lines.joined(separator: "\n")
    try jsonl.write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    let report = ClaudeUsageReader(root: dir.deletingLastPathComponent()).read(since: Date(timeIntervalSince1970: 0))
    #expect(report.messages == 2)
    #expect(report.byModel["claude-opus-5-5"]?.output == 500)
    let opus: Double = 1000 * 4 + 500 * 20
    let haiku: Double = 2000 * 0.1 + 1000 * 0.5
    let expected: Double = (opus + haiku) / 1_000_000
    #expect(abs(report.totalCost - expected) < 1e-9)
  }

  @Test func modelosDesconocidosUsanLaFamilia() {
    #expect(ModelPricing.price(for: "claude-sonnet-9-9")?.input == ModelPricing.price(for: "claude-sonnet-5-5")?.input)
    #expect(ModelPricing.price(for: "gpt-algo") == nil)
  }
}

@Suite struct ClaudeStatusTests {
  @Test func leeLosLimitesDelJSONDeLaBarraDeEstado() throws {
    let json = #"{"session_id":"s1","cwd":"/Users/demo/proyecto","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"cost":{"total_cost_usd":1.25},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}"#
    let s = try StatusSnapshot.decode(Data(json.utf8))
    #expect(s.fiveHour?.usedPercentage == 23.5)
    #expect(s.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1738857600))
    #expect(s.sessionCost == 1.25)
    #expect(s.projectName == "proyecto")
  }

  @Test func sinLimitesNoFalla() throws {
    let s = try StatusSnapshot.decode(Data(#"{"session_id":"s1"}"#.utf8))
    #expect(s.fiveHour == nil && s.sevenDay == nil)
  }

  @Test func eventosDeHooksCambianElEstadoDeLaSesion() {
    var board = ClaudeActivityBoard()
    let t = Date()
    #expect(board.apply(HookEvent(name: "UserPromptSubmit", sessionID: "s1", cwd: "/x/kivo", date: t, message: nil)) == nil)
    #expect(board.sessions["s1"]?.state == .working)
    let waiting = board.apply(HookEvent(name: "PermissionRequest", sessionID: "s1", cwd: "/x/kivo", date: t, message: nil))
    #expect(board.sessions["s1"]?.state == .waiting)
    #expect(waiting == .needsYou(project: "kivo"))
    let done = board.apply(HookEvent(name: "Stop", sessionID: "s1", cwd: "/x/kivo", date: t.addingTimeInterval(90), message: nil))
    #expect(done == .finished(project: "kivo", seconds: 90))
    #expect(board.sessions["s1"]?.state == .idle)
    #expect(board.workingCount == 0)
  }
}

@Suite struct ClaudeIntegrationTests {
  let exe = "/Applications/Faro.app/Contents/MacOS/Faro"

  @Test func instalaSinBorrarLoQueYaHabia() throws {
    let original: [String: Any] = [
      "statusLine": ["type": "command", "command": "bash ~/.claude/statusline-command.sh"],
      "hooks": ["Stop": [["hooks": [["type": "command", "command": "say listo"]]]]],
      "model": "opus",
    ]
    let r = ClaudeIntegration.install(into: original, executable: exe)
    let status = r.settings["statusLine"] as! [String: Any]
    #expect((status["command"] as! String).contains("--claude-statusline"))
    #expect(r.previousStatusLine == "bash ~/.claude/statusline-command.sh")
    let hooks = r.settings["hooks"] as! [String: Any]
    let stop = hooks["Stop"] as! [[String: Any]]
    #expect(stop.count == 2)
    #expect(ClaudeIntegration.isInstalled(r.settings))
    #expect(r.settings["model"] as? String == "opus")
    // Instalar dos veces no duplica.
    let again = ClaudeIntegration.install(into: r.settings, executable: exe)
    #expect(((again.settings["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count == 2)
  }

  @Test func desinstalarDejaTodoComoEstaba() throws {
    let original: [String: Any] = [
      "statusLine": ["type": "command", "command": "bash ~/.claude/statusline-command.sh"],
      "hooks": ["Stop": [["hooks": [["type": "command", "command": "say listo"]]]]],
    ]
    let r = ClaudeIntegration.install(into: original, executable: exe)
    let back = ClaudeIntegration.uninstall(from: r.settings, previousStatusLine: r.previousStatusLine)
    #expect(!ClaudeIntegration.isInstalled(back))
    #expect((back["statusLine"] as! [String: Any])["command"] as? String == "bash ~/.claude/statusline-command.sh")
    #expect(((back["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count == 1)
    #expect((back["hooks"] as! [String: Any])["UserPromptSubmit"] == nil)
  }
}

@Suite struct BrewTests {
  @Test func leeBrewOutdated() throws {
    let json = #"{"formulae":[{"name":"whisper-cpp","installed_versions":["1.9.4"],"current_version":"1.9.5","pinned":false}],"casks":[{"name":"stremio","installed_versions":["5.0.1"],"current_version":"5.0.2"}]}"#
    let items = try BrewOutdated.parse(Data(json.utf8))
    #expect(items.count == 2)
    #expect(items[0] == BrewPackage(name: "whisper-cpp", installed: "1.9.4", latest: "1.9.5", isCask: false))
    #expect(items[1].isCask)
  }
}

@Suite struct UsageCacheTests {
  func line(_ id: String, _ out: Int, _ ts: String) -> String {
    #"{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_"# + id + #"","content":[{"type":"text","text":"el usage es \"model\":\"x\" y {llaves}"}],"usage":{"input_tokens":10,"output_tokens":"# + String(out) + #","cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"timestamp":""# + ts + #""}"#
  }

  @Test func elParserRapidoIgnoraElContenido() {
    let parsed = UsageLineParser.parse(Substring(line("a", 7, "2026-10-22T10:00:00Z")))
    #expect(parsed?.model == "claude-opus-5-5")
    #expect(parsed?.id == "msg_a")
    #expect(parsed?.usage.output == 7)
  }

  @Test func laCacheLeeSoloLoNuevo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("uso-\(UUID().uuidString)")
    let proj = root.appendingPathComponent("p")
    try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    let file = proj.appendingPathComponent("s.jsonl")
    try (line("a", 100, "2026-10-22T10:00:00Z") + "\n").write(to: file, atomically: true, encoding: .utf8)
    let cacheFile = root.appendingPathComponent("cache.json")
    let cache = UsageCache(root: root, cacheFile: cacheFile)
    #expect(cache.refresh().byModel["claude-opus-5-5"]?.output == 100)
    let h = try FileHandle(forWritingTo: file)
    h.seekToEndOfFile()
    h.write(Data((line("a", 100, "2026-10-22T10:00:00Z") + "\n" + line("b", 50, "2026-10-22T11:00:00Z") + "\n").utf8))
    try h.close()
    let r = cache.refresh()
    #expect(r.byModel["claude-opus-5-5"]?.output == 150)
    // Una instancia nueva parte de la caché guardada en disco y da lo mismo.
    #expect(UsageCache(root: root, cacheFile: cacheFile).refresh().byModel["claude-opus-5-5"]?.output == 150)
  }
}
