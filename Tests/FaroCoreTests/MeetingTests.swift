import Foundation
import Testing
@testable import FaroCore

@Suite(.serialized) struct MeetingTests {
  func voice(_ s: Double) -> [Float] { (0..<Int(s * 16000)).map { Float(sin(Double($0) * 0.05)) * 0.3 } }
  func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16000)) }

  @Test func elCortadorDeReunionesEsperaQuinceSegundos() {
    let audio = voice(10) + silence(0.6) + voice(8) + silence(0.6) + voice(2)
    let cut = SpeechSegmenter.nextCut(in: audio, from: 0, sampleRate: 16000, minSegment: 15, maxSegment: 28)
    #expect(cut != nil)
    #expect(Double(cut!) / 16000 > 18 && Double(cut!) / 16000 < 19)
  }

  @Test func transcribeTramosConMarcasDeTiempoYLosGuardaAlVuelo() async throws {
    let t = RecordingTranscriber()
    let box = SavedBox()
    let m = MeetingTranscriber(transcriber: t, sampleRate: 16000, dictionary: .default) { box.set($0) }
    let audio = voice(16) + silence(0.6) + voice(5) + silence(0.5)
    for i in stride(from: 0, to: audio.count, by: 1600) { m.append(Array(audio[i..<min(audio.count, i + 1600)])) }
    // El primer tramo se guarda solo, sin esperar al final (con margen para una máquina ocupada).
    for _ in 0..<60 where box.get().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    #expect(box.get().count == 1)
    let segments = try await m.finish()
    #expect(segments.map(\.text) == ["parte1", "parte2"])
    #expect(segments[0].start == 0)
    #expect(segments[1].start > 16 && segments[1].start < 17)
    #expect(box.get().count == 2)
  }

  @Test func almacenGuardaListaYRecuperaInterrumpidas() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reuniones-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = MeetingStore(root: dir)
    var m = Meeting(startedAt: Date(), includesSystemAudio: false)
    m.status = .recording
    m.segments = [TranscriptSegment(start: 0, end: 20, text: "hola")]
    try store.save(m)
    #expect(store.list().count == 1)
    let recovered = store.recoverInterrupted()
    #expect(recovered == 1)
    #expect(store.load(m.id)?.status == .interrupted)
    try store.delete(m.id)
    #expect(store.list().isEmpty)
  }

  @Test func elResumenSeLeeDelJSONEstructurado() throws {
    let json = #"{"titulo":"Kickoff Kivo","resumen":"Se acordó el alcance.","puntos_clave":["Alcance v1"],"decisiones":["Usar Supabase"],"tareas":[{"descripcion":"Enviar propuesta","responsable":"Daniel","fecha":"viernes"}],"pendientes":["Definir precios"]}"#
    let s = try MeetingSummary.decode(Data(json.utf8))
    #expect(s.title == "Kickoff Kivo")
    #expect(s.tasks.first?.owner == "Daniel")
    let md = MeetingExport.markdown(Meeting(startedAt: Date(timeIntervalSince1970: 0), includesSystemAudio: false, summary: s))
    #expect(md.contains("# Kickoff Kivo"))
    #expect(md.contains("- [ ] Enviar propuesta (Daniel, viernes)"))
  }

  @Test func laPeticionDeResumenUsaHaikuYSalidaEstructurada() throws {
    let req = try MeetingSummarizer(apiKey: "sk-ant-prueba").makeRequest(transcript: "[00:00] hola")
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    #expect(body["model"] as? String == "claude-haiku-5-5")
    let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
    #expect(format?["type"] as? String == "json_schema")
  }

  @Test func elVocabularioViajaConLaTranscripcion() {
    let c = MeetingSummarizer.userContent(transcript: "[00:00] pagos con bumpi", vocabulary: ["Wompi"])
    #expect(c.contains("<vocabulario>") && c.contains("Wompi") && c.contains("<transcripcion>"))
  }

  @Test func transcripcionConMarcasDeTiempo() {
    let segs = [TranscriptSegment(start: 0, end: 20, text: "Buenas"), TranscriptSegment(start: 3725, end: 3740, text: "Cerramos")]
    #expect(MeetingExport.timestamped(segs) == "[00:00] Buenas\n[1:02:05] Cerramos")
  }
}

final class SavedBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: [TranscriptSegment] = []
  func set(_ v: [TranscriptSegment]) { lock.withLock { value = v } }
  func get() -> [TranscriptSegment] { lock.withLock { value } }
}

@Suite struct MeetingSummaryLiveTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
  func resumenRealConHaiku() async throws {
    let transcript = """
    [00:00] Bueno, arrancamos. La idea es definir el alcance de la app de Kivo para la primera versión.
    [00:20] Lo más importante es el login, los pagos con Wompi y el panel de inventario.
    [01:05] Decidimos usar Supabase para la base de datos y Vercel para el frontend.
    [01:40] Yo me encargo de enviar la propuesta el viernes. Carlos revisa los precios la otra semana.
    [02:10] Queda pendiente definir si hay app móvil o solo web.
    """
    let s = try await MeetingSummarizer(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]).summarize(transcript: transcript)
    #expect(!s.title.isEmpty)
    #expect(s.decisions.joined().contains("Supabase"))
    #expect(s.tasks.contains { $0.description.lowercased().contains("propuesta") })
    #expect(!s.openQuestions.isEmpty)
  }
}
