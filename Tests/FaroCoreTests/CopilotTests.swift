import Foundation
import Testing
@testable import FaroCore

@Suite(.serialized) struct CopilotTests {
  static let ficha = """
  # Ficha de prueba: Kivo
  - Stack: Next.js 16 con TypeScript, base de datos Postgres en Supabase, alojado en Vercel.
  - Servidores en la región de São Paulo (sa-east-1).
  - Cada cliente solo ve sus datos: políticas RLS de Postgres por organización.
  - Copias de seguridad diarias que Supabase guarda 7 días.
  - Lo que NO se debe afirmar: no tiene certificación ISO 27001.
  """

  func seg(_ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(start: start, end: start + 4, text: text)
  }

  @Test func leeLasFichasDeLaCarpetaConSuNombre() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fichas-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "contenido de acme".write(to: dir.appendingPathComponent("Acme.md"), atomically: true, encoding: .utf8)
    try "   ".write(to: dir.appendingPathComponent("Vacia.md"), atomically: true, encoding: .utf8)
    try "no".write(to: dir.appendingPathComponent("notas.txt"), atomically: true, encoding: .utf8)
    let k = MeetingCopilot.loadKnowledge(from: dir)
    #expect(k.names == ["Acme"])
    #expect(k.text.contains("<ficha nombre=\"Acme\">"))
    #expect(k.text.contains("contenido de acme"))
  }

  @Test func laCarpetaVaciaDesactivaElCopiloto() {
    #expect(MeetingCopilot.folder(fromSetting: "  ") == nil)
    #expect(MeetingCopilot.folder(fromSetting: "~/Notas")?.path == NSHomeDirectory() + "/Notas")
  }

  @Test func soloMiraElUltimoMinutoYAlgo() {
    let segs = [seg(0, "viejo"), seg(50, "medio"), seg(120, "nuevo")]
    #expect(MeetingCopilot.recent(segs).map(\.text) == ["medio", "nuevo"])
  }

  @Test func laPeticionLlevaLasFichasConCacheYElEsquema() async throws {
    let c = MeetingCopilot(apiKey: "k", knowledge: "FICHA")
    let req = try await c.makeRequest(recent: [seg(0, "¿dónde están los servidores?")])
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    let system = body["system"] as! [[String: Any]]
    #expect((system.last?["text"] as? String)?.contains("FICHA") == true)
    #expect(system.last?["cache_control"] != nil)
    #expect(body["output_config"] != nil)
    let user = ((body["messages"] as! [[String: Any]])[0]["content"] as! String)
    #expect(user.contains("[00:00] ¿dónde están los servidores?"))
  }

  @Test func leeLaDecisionDelModelo() {
    let inner = #"{"hay_pregunta":true,"pregunta":"¿Dónde están los servidores?","respuesta":"En São Paulo.","en_la_ficha":true}"#
    let outer = try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": inner]]])
    let d = MeetingCopilot.parse(outer)
    #expect(d?.hasQuestion == true)
    #expect(d?.answer == "En São Paulo.")
  }

  @Test func reconoceUnaPreguntaRepetida() {
    let a = MeetingCopilot.words("¿Dónde están alojados los servidores?")
    let b = MeetingCopilot.words("donde estan alojados servidores")
    #expect(a == b)
  }

  /// Con la API real: responde con el dato de la ficha, no responde la charla y no inventa la certificación.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
  func conLaApiRealRespondeSoloLoQueHayQueResponder() async throws {
    let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!
    let c = MeetingCopilot(apiKey: key, knowledge: Self.ficha)

    let charla = await c.consider([seg(0, "Bueno, muchas gracias por el espacio, ¿cómo están todos por allá en Bogotá?")])
    #expect(charla.isEmpty)

    let t0 = Date()
    let r = await c.consider([
      seg(10, "Listo, ya vimos la parte de las órdenes de trabajo."),
      seg(14, "Una pregunta, ¿y los datos dónde quedan guardados, en qué servidores?"),
    ])
    let took = Date().timeIntervalSince(t0)
    #expect(r.count == 1)
    #expect(r.first?.answer.contains("Paulo") == true)
    #expect(r.first?.inNotes == true)
    #expect(took < 8)

    // La misma pregunta otra vez no se responde de nuevo.
    let again = await c.consider([seg(20, "Perdón, entonces ¿en qué servidores quedan guardados los datos?")])
    #expect(again.isEmpty)

    let iso = await c.consider([seg(30, "¿Ustedes tienen certificación ISO 27001?")])
    #expect(iso.count == 1)
    #expect(iso.first?.inNotes == false || iso.first?.answer.lowercased().contains("no") == true)
  }
}

/// Prueba de punta a punta con las notas reales (carpeta en COPILOTO_NOTAS o la de por defecto): lee una reunión simulada (una línea por tramo ya
/// transcrito por Whisper) desde COPILOTO_E2E y muestra qué respondería el copiloto y cuánto tarda.
@Suite struct CopilotE2E {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["COPILOTO_E2E"] != nil
                   && ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
  func reunionSimuladaConLasNotasReales() async throws {
    let env = ProcessInfo.processInfo.environment
    let lines = try String(contentsOfFile: env["COPILOTO_E2E"]!, encoding: .utf8).split(separator: "\n").map(String.init)
    let folder = env["COPILOTO_NOTAS"].flatMap { MeetingCopilot.folder(fromSetting: $0) } ?? MeetingCopilot.defaultFolder
    let notes = MeetingCopilot.loadKnowledge(from: folder)
    #expect(!notes.names.isEmpty)
    let c = MeetingCopilot(apiKey: env["ANTHROPIC_API_KEY"]!, knowledge: notes.text)
    var segments: [TranscriptSegment] = []
    var answered = 0
    for (i, line) in lines.enumerated() {
      segments.append(TranscriptSegment(start: Double(i * 8), end: Double(i * 8 + 6), text: line))
      let t0 = Date()
      let r = await c.consider(segments)
      let took = Date().timeIntervalSince(t0)
      print("TRAMO \(i + 1) (\(String(format: "%.1f", took)) s): \(line)")
      for a in r {
        answered += 1
        print("  -> [\(a.inNotes ? "ficha" : "NO está en la ficha")] \(a.question)\n     \(a.answer)")
      }
    }
    #expect(answered >= 4)
  }
}
