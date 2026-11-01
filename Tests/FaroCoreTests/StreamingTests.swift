import Foundation
import Testing
@testable import FaroCore

final class RecordingTranscriber: Transcriber, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var calls: [(samples: Int, prompt: String, at: Date)] = []
  func transcribe(_ samples: [Float], sampleRate: Int, prompt: String) async throws -> String {
    let n = lock.withLock {
      calls.append((samples.count, prompt, Date()))
      return calls.count
    }
    try await Task.sleep(for: .milliseconds(150))
    return "parte\(n)"
  }
}

@Suite struct StreamingTests {
  func voice(_ s: Double) -> [Float] { (0..<Int(s * 16000)).map { Float(sin(Double($0) * 0.05)) * 0.3 } }
  func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16000)) }

  @Test func transcribeLaPrimeraParteAntesDeSoltarYUneElTexto() async throws {
    let t = RecordingTranscriber()
    let d = StreamingDictation(transcriber: t, sampleRate: 16000, dictionary: .default)
    let audio = voice(3.5) + silence(0.6) + voice(1.2) + silence(0.3)
    for chunk in stride(from: 0, to: audio.count, by: 640) {
      d.append(Array(audio[chunk..<min(audio.count, chunk + 640)]))
    }
    try await Task.sleep(for: .milliseconds(400))
    let beforeFinish = Date()
    #expect(t.calls.count == 1)
    let text = try await d.finish()
    #expect(text == "parte1 parte2")
    #expect(t.calls.count == 2)
    #expect(t.calls[0].at < beforeFinish)
    #expect(t.calls[1].prompt.contains("parte1"))
  }

  @Test func sinVozDevuelveVacioSinLlamar() async throws {
    let t = RecordingTranscriber()
    let d = StreamingDictation(transcriber: t, sampleRate: 16000, dictionary: .default)
    d.append(silence(2))
    #expect(try await d.finish() == "")
    #expect(t.calls.isEmpty)
  }
}
