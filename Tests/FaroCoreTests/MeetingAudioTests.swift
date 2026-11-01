import Foundation
import Testing
@testable import FaroCore

@Suite struct AudioConditionerTests {
  func tone(_ seconds: Double, amplitude: Float) -> [Float] {
    (0..<Int(seconds * 16000)).map { Float(sin(Double($0) * 2 * .pi * 220 / 16000)) * amplitude }
  }

  @Test func subeUnaVozLejanaANivelNormal() {
    let quiet = tone(4, amplitude: 0.008)  // ≈ −45 dBFS, como el profesor en el salón
    #expect(AudioConditioner.rmsDBFS(quiet) < -43)
    let out = AudioConditioner.forDistantSpeech(quiet, sampleRate: 16000)
    // Pasado el primer segundo (la ganancia sube suave), queda cerca del objetivo.
    let level = AudioConditioner.rmsDBFS(Array(out[16000...]))
    #expect(level > -27 && level < -20)
  }

  @Test func noAmplificaElSilencio() {
    let hiss = (0..<32000).map { _ in Float.random(in: -0.0004...0.0004) }  // ≈ −74 dBFS
    let out = AudioConditioner.forDistantSpeech(hiss, sampleRate: 16000)
    #expect(AudioConditioner.rmsDBFS(out) < -60)
  }

  @Test func quitaElRetumboGrave() {
    let rumble = (0..<32000).map { Float(sin(Double($0) * 2 * .pi * 30 / 16000)) * 0.1 }  // 30 Hz
    let filtered = AudioConditioner.forDistantSpeech(rumble, sampleRate: 16000)
    // Sin la ganancia, el paso alto deja el 30 Hz bastante más bajo; con ganancia, igual no satura.
    #expect(filtered.allSatisfy { abs($0) <= 0.98 })
  }
}

@Suite struct RepetitionFilterTests {
  @Test func dejaUnaSolaFraseRepetida() {
    let raw = "La urgencia de Madrid es un gran consejo.\n La urgencia de Madrid es un gran consejo.\n La urgencia de Madrid es un gran consejo."
    #expect(RepetitionFilter.clean(raw) == "La urgencia de Madrid es un gran consejo.")
  }

  @Test func quitaPalabrasRepetidasSeguidas() {
    #expect(RepetitionFilter.clean("el próximo fin de semana la pandemia, la pandemia y ya") == "el próximo fin de semana la pandemia, y ya")
  }

  @Test func descartaGraciasSuelto() {
    #expect(RepetitionFilter.clean("Gracias.\n Gracias.") == nil)
    #expect(RepetitionFilter.clean("¡Gracias!") == nil)
  }

  @Test func noTocaUnTextoNormal() {
    let t = "Bueno, la práctica es para el próximo fin de semana. ¿Alguna pregunta?"
    #expect(RepetitionFilter.clean(t) == t)
  }
}

@Suite struct RobustMeetingTests {
  @Test func unaVozBajaSeTranscribeYNoSeArrastraContexto() async throws {
    let t = RecordingTranscriber()
    let m = MeetingTranscriber(transcriber: t, sampleRate: 16000, dictionary: .default) { _ in }
    // Voz a ≈ −50 dBFS: antes el recorte de silencios la tomaba por silencio y no se transcribía nada.
    let quietVoice = { (s: Double) in (0..<Int(s * 16000)).map { Float(sin(Double($0) * 0.05)) * 0.004 } }
    let audio = quietVoice(16) + [Float](repeating: 0, count: 9600) + quietVoice(5) + [Float](repeating: 0, count: 8000)
    for i in stride(from: 0, to: audio.count, by: 1600) { m.append(Array(audio[i..<min(audio.count, i + 1600)])) }
    let segments = try await m.finish()
    #expect(segments.map(\.text) == ["parte1", "parte2"])
    // El corte cae en la pausa, no a la fuerza a los 28 s.
    #expect(segments.count == 2 && segments[1].start > 16 && segments[1].start < 17)
    try #require(t.calls.count == 2)
    #expect(!t.calls[1].prompt.contains("parte1"))
  }
}

@Suite struct MeetingAudioFileTests {
  @Test func lasNuevasGrabacionesVanEnAACyLasViejasSeSiguenEncontrando() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = MeetingStore(root: dir)
    let id = UUID()
    #expect(store.audioURL(id).lastPathComponent == "audio.aac")
    #expect(store.recordingURL(id).lastPathComponent == "audio.aac")
    try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
    try Data().write(to: store.folder(id).appendingPathComponent("audio.m4a"))
    #expect(store.audioURL(id).lastPathComponent == "audio.m4a")
  }
}

@Suite struct MeetingGroupsTests {
  func meeting(_ minutesAgo: Double, _ group: String?) -> Meeting {
    var m = Meeting(startedAt: Date().addingTimeInterval(-minutesAgo * 60), includesSystemAudio: false)
    m.group = group
    return m
  }

  @Test func agrupaPorNombreYDejaLasSueltasAlFinal() {
    let list = [meeting(5, "Visualización de datos"), meeting(50, nil), meeting(10, " Visualización de datos "),
                meeting(30, "Sistemas"), meeting(1, nil)]
    let s = MeetingGroups.sections(list)
    #expect(s.map(\.name) == ["Visualización de datos", "Sistemas", nil])
    #expect(s[0].meetings.count == 2)
    #expect(s[2].meetings.count == 2)
  }

  @Test func unGrupoVacioEsSinGrupo() {
    #expect(MeetingGroups.normalized("   ") == nil)
    #expect(MeetingGroups.normalized(" Clase ") == "Clase")
  }

  @Test func reunionesViejasSinGrupoSeLeen() throws {
    let json = #"{"id":"14CEF74C-A07C-492A-A38B-F346D5C10340","startedAt":"2026-10-23T23:07:56Z","duration":74,"status":"ready","includesSystemAudio":false,"segments":[]}"#
    let m = try JSONDecoder.iso.decode(Meeting.self, from: Data(json.utf8))
    #expect(m.group == nil)
  }
}
