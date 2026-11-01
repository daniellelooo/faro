import Foundation
import Testing
@testable import FaroCore

final class FakeTranscriber: Transcriber, @unchecked Sendable {
  var calls = 0
  let text: String
  init(_ text: String) { self.text = text }
  func transcribe(_ samples: [Float], sampleRate: Int, prompt: String) async throws -> String {
    calls += 1
    return text
  }
}

final class FakeCleaner: Cleaner, @unchecked Sendable {
  var calls = 0
  let result: CleanResult?
  init(_ result: CleanResult? = nil) { self.result = result }
  func clean(_ raw: String, tone: Tone, dictionary: PersonalDictionary, context: ScreenContext?) async -> CleanResult {
    calls += 1
    return result ?? CleanResult(text: "LIMPIO", usedFallback: false)
  }
}

func tone(seconds: Double, sampleRate: Int = 16000) -> [Float] {
  (0..<Int(seconds * Double(sampleRate))).map { Float(sin(Double($0) * 0.06)) * 0.3 }
}

@Suite struct PipelineTests {
  let longText = "eh bueno la reunión es el miércoles a las tres de la tarde"

  @Test func silencioSeSaltaSinLlamarANada() async throws {
    let t = FakeTranscriber(longText), c = FakeCleaner()
    let p = DictationPipeline(transcriber: t, cleaner: c, dictionary: .default)
    let r = try await p.run(samples: [Float](repeating: 0.0005, count: 32000), sampleRate: 16000, tone: .neutral, localOnly: false)
    #expect(r.skipped)
    #expect(t.calls == 0 && c.calls == 0)
  }

  @Test func menosDeTresDecimasSeSalta() async throws {
    let t = FakeTranscriber(longText)
    let p = DictationPipeline(transcriber: t, cleaner: FakeCleaner(), dictionary: .default)
    let samples = [Float](repeating: 0, count: 8000) + tone(seconds: 0.2) + [Float](repeating: 0, count: 8000)
    let r = try await p.run(samples: samples, sampleRate: 16000, tone: .neutral, localOnly: false)
    #expect(r.skipped && t.calls == 0)
  }

  @Test func soloLocalNoLlamaAlLimpiador() async throws {
    let c = FakeCleaner()
    let p = DictationPipeline(transcriber: FakeTranscriber(longText), cleaner: c, dictionary: .default)
    let r = try await p.run(samples: tone(seconds: 2), sampleRate: 16000, tone: .neutral, localOnly: true)
    #expect(c.calls == 0 && r.final == longText && !r.skipped)
  }

  @Test func conLimpiezaUsaElTextoLimpio() async throws {
    let p = DictationPipeline(transcriber: FakeTranscriber(longText), cleaner: FakeCleaner(), dictionary: .default)
    let r = try await p.run(samples: tone(seconds: 2), sampleRate: 16000, tone: .neutral, localOnly: false)
    #expect(r.final == "LIMPIO" && r.raw == longText)
  }

  @Test func respaldoDejaElCrudo() async throws {
    let c = FakeCleaner(CleanResult(text: longText, usedFallback: true, reason: "Sin conexión"))
    let p = DictationPipeline(transcriber: FakeTranscriber(longText), cleaner: c, dictionary: .default)
    let r = try await p.run(samples: tone(seconds: 2), sampleRate: 16000, tone: .neutral, localOnly: false)
    #expect(r.final == r.raw && r.usedFallback && r.fallbackReason == "Sin conexión")
  }

  @Test func ruidoInventadoPorWhisperSeSalta() async throws {
    let c = FakeCleaner()
    let p = DictationPipeline(transcriber: FakeTranscriber("[BLANK_AUDIO]"), cleaner: c, dictionary: .default)
    let r = try await p.run(samples: tone(seconds: 1), sampleRate: 16000, tone: .neutral, localOnly: false)
    #expect(r.skipped && c.calls == 0)
  }
}
