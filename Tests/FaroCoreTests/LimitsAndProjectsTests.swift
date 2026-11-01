import Foundation
import Testing
@testable import FaroCore

@Suite struct PlanLimitsTests {
  @Test func leeElEndpointDeUso() throws {
    let json = #"""
    {"five_hour":{"utilization":77.0,"resets_at":"2026-10-22T16:30:00.192+00:00"},
     "seven_day":{"utilization":3.0,"resets_at":"2026-10-29T15:00:00+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":{"utilization":0,"resets_at":null},
     "limits":[{"kind":"weekly","group":"model","percent":12,"resets_at":"2026-10-29T15:00:00Z","scope":{"model":{"display_name":"Fable"}}},
               {"kind":"weekly","group":"all","percent":3}],
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
    """#
    let l = try PlanUsageParser.parse(Data(json.utf8))
    #expect(l.fiveHour?.percent == 77)
    #expect(l.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_792_686_600.192))
    #expect(l.sevenDay?.percent == 3)
    #expect(l.models.map(\.title) == ["Fable"])
    #expect(l.models.first?.percent == 12)
    #expect(l.source == .account)
  }

  @Test func leeLosEncabezadosDeLimite() {
    let h = ["Anthropic-Ratelimit-Unified-5h-Utilization": "0.04", "anthropic-ratelimit-unified-5h-reset": "1792704600",
             "anthropic-ratelimit-unified-7d-utilization": "0.03", "anthropic-ratelimit-unified-7d-reset": "1793286000",
             "content-type": "application/json"]
    let l = PlanUsageClient.limits(fromHeaders: h)
    #expect(l?.fiveHour?.percent == 4)
    #expect(l?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_792_704_600))
    #expect(l?.sevenDay?.percent == 3)
    #expect(PlanUsageClient.limits(fromHeaders: ["content-type": "x"]) == nil)
  }

  @Test func unaRespuestaSinVentanasEsError() {
    #expect(throws: (any Error).self) { try PlanUsageParser.parse(Data(#"{"extra_usage":null}"#.utf8)) }
  }

  @Test func elHistorialDeEscritorioSoloSirveSiEsReciente() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).json")
    let t = 1_792_686_000_000.0
    try #"{"version":2,"samples":[{"t":1792600000000,"org":"o","u":{"fh":10,"sd":40}},{"t":\#(Int(t)),"org":"o","u":{"fh":55,"sd":20}}]}"#
      .write(to: file, atomically: true, encoding: .utf8)
    let fresh = DesktopUsageHistory.latest(file: file, now: Date(timeIntervalSince1970: t / 1000 + 600))
    #expect(fresh?.fiveHour?.percent == 55)
    #expect(fresh?.sevenDay?.percent == 20)
    #expect(fresh?.source == .desktop)
    #expect(DesktopUsageHistory.latest(file: file, now: Date(timeIntervalSince1970: t / 1000 + 3600)) == nil)
  }

  @Test func laBarraDeEstadoSeConvierte() throws {
    let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1792700000}}}"#.utf8)
    let l = PlanLimits(snapshot: try StatusSnapshot.decode(data))
    #expect(l?.fiveHour?.percent == 12)
    #expect(l?.sevenDay == nil)
    #expect(PlanLimits(snapshot: try StatusSnapshot.decode(Data("{}".utf8))) == nil)
  }
}

@Suite struct ProjectUsageTests {
  func line(_ id: String, _ cwd: String, _ ts: String) -> String {
    #"{"type":"assistant","cwd":""# + cwd + #"","message":{"model":"claude-opus-5-5","id":"msg_"# + id + #"","usage":{"input_tokens":0,"output_tokens":1000000}},"timestamp":""# + ts + #""}"#
  }

  @Test func agrupaPorCarpetaYNoCuentaSubagentesComoSesion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("proy-\(UUID().uuidString)")
    let a = root.appendingPathComponent("a")
    try FileManager.default.createDirectory(at: a.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
    try (line("1", "/x/kivo", "2026-10-22T10:00:00Z") + "\n").write(to: a.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    try (line("2", "/x/kivo", "2026-10-22T10:05:00Z") + "\n").write(to: a.appendingPathComponent("s1/subagents/agent-1.jsonl"), atomically: true, encoding: .utf8)
    try (line("3", "/x/datavia", "2026-10-21T09:00:00Z") + "\n").write(to: a.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
    let r = UsageCache(root: root, cacheFile: root.appendingPathComponent("c.json")).refresh()
    let kivo = try #require(r.projects.first { $0.path == "/x/kivo" })
    #expect(kivo.sessions == 1)
    #expect(kivo.name == "kivo")
    // 1M de salida en Opus 5.5 = $20, dos veces.
    #expect(abs(kivo.costByDay.values.reduce(0, +) - 40) < 0.001)
    #expect(r.projects.contains { $0.path == "/x/datavia" && $0.sessions == 1 })
  }

  @Test func unaCacheViejaSinCarpetaLaRecupera() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("proy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("s.jsonl")
    try (line("1", "/x/faro", "2026-10-22T10:00:00Z") + "\n").write(to: file, atomically: true, encoding: .utf8)
    let cacheFile = root.appendingPathComponent("c.json")
    _ = UsageCache(root: root, cacheFile: cacheFile).refresh()
    // Simula la caché de la versión anterior: sin "cwd".
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as! [String: [String: Any]]
    for k in json.keys { json[k]?["cwd"] = nil }
    try JSONSerialization.data(withJSONObject: json).write(to: cacheFile)
    let r = UsageCache(root: root, cacheFile: cacheFile).refresh()
    #expect(r.projects.map(\.path) == ["/x/faro"])
  }
}
