import Foundation
import Testing
@testable import FaroCore

@Suite(.serialized) struct CleanerTests {
  let raw = "eh bueno la reunión es el martes no perdón el miércoles"

  func cleaner(timeout: TimeInterval = 3) -> AnthropicCleaner {
    AnthropicCleaner(apiKey: "sk-ant-prueba", session: MockURLProtocol.session(), timeout: timeout)
  }

  @Test func devuelveElTextoDelBloqueText() async throws {
    MockURLProtocol.handler = { _ in
      (200, Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"La reunión es el miércoles."}],"stop_reason":"end_turn"}"#.utf8))
    }
    let r = await cleaner().clean(raw, tone: .neutral, dictionary: .default)
    #expect(r == CleanResult(text: "La reunión es el miércoles.", usedFallback: false))
    let body = try JSONSerialization.jsonObject(with: MockURLProtocol.lastBody!) as! [String: Any]
    #expect(body["model"] as? String == "claude-haiku-5-5")
    #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
  }

  @Test(arguments: [401, 429, 500, 529])
  func erroresDeLaAPIDevuelvenElCrudo(status: Int) async {
    MockURLProtocol.handler = { _ in (status, Data(#"{"type":"error"}"#.utf8)) }
    let r = await cleaner().clean(raw, tone: .neutral, dictionary: .default)
    #expect(r.text == raw)
    #expect(r.usedFallback)
    #expect(r.reason != nil)
  }

  @Test func siLaPrimeraPeticionSeDemoraGanaLaDeRespaldo() async {
    MockURLProtocol.requestCount = 0
    MockURLProtocol.delay = { n in n == 1 ? 2.5 : 0 }
    defer { MockURLProtocol.delay = nil }
    MockURLProtocol.handler = { _ in
      (200, Data(#"{"content":[{"type":"text","text":"Rápido."}],"stop_reason":"end_turn"}"#.utf8))
    }
    let start = Date()
    let r = await cleaner().clean(raw, tone: .neutral, dictionary: .default)
    #expect(r == CleanResult(text: "Rápido.", usedFallback: false))
    #expect(Date().timeIntervalSince(start) < 2.0)
  }

  @Test func unErrorDeLaSegundaNoTapaLaRespuestaDeLaPrimera() async {
    MockURLProtocol.requestCount = 0
    MockURLProtocol.delay = { n in n == 1 ? 1.6 : 0 }
    defer { MockURLProtocol.delay = nil }
    MockURLProtocol.perRequest = { n in
      n == 1
        ? (200, Data(#"{"content":[{"type":"text","text":"Llegó."}],"stop_reason":"end_turn"}"#.utf8))
        : (429, Data(#"{"type":"error"}"#.utf8))
    }
    defer { MockURLProtocol.perRequest = nil }
    let r = await cleaner().clean(raw, tone: .neutral, dictionary: .default)
    #expect(r == CleanResult(text: "Llegó.", usedFallback: false))
  }

  @Test func sinConexionDevuelveElCrudo() async {
    MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
    let r = await cleaner().clean(raw, tone: .neutral, dictionary: .default)
    #expect(r.text == raw && r.usedFallback && r.reason == "Sin conexión")
  }

  @Test func sinClaveDevuelveElCrudo() async {
    let r = await AnthropicCleaner(apiKey: nil).clean(raw, tone: .neutral, dictionary: .default)
    #expect(r.text == raw && r.usedFallback)
  }

  @Test func heuristicaSaltaDictadosCortosSinMuletillas() {
    #expect(!CleanupHeuristics.needsCleanup("Listo, gracias."))
    #expect(CleanupHeuristics.needsCleanup("eh listo"))
    #expect(CleanupHeuristics.needsCleanup("uno dos tres cuatro cinco seis siete"))
  }

  /// Usa ANTHROPIC_API_KEY (scripts/test.sh la toma del Llavero con `security`, sin ventana de contraseña).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
  func limpiezaRealConClaude() async {
    let real = AnthropicCleaner(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], timeout: 10)
    let r = await real.clean(raw, tone: .neutral, dictionary: .default)
    #expect(!r.usedFallback)
    #expect(r.text.contains("miércoles"))
    #expect(!r.text.contains("martes"))
  }
}

