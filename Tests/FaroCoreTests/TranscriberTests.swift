import Foundation
import Testing
@testable import FaroCore

@Suite(.serialized) struct TranscriberTests {
  @Test func wavTieneEncabezadoRIFF() {
    let wav = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1], sampleRate: 16000)
    #expect(wav.count == 44 + 8)
    #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
    #expect(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
  }

  @Test func modeloAusenteDaErrorEnEspanol() async {
    let server = WhisperServer(modelPath: "/no/existe.bin")
    await #expect(throws: DictaError.modelMissing("/no/existe.bin")) { try await server.start() }
  }

  @Test(.enabled(if: FileManager.default.fileExists(atPath: WhisperServer.defaultModelPath)))
  func transcribeAudioRealEnEspanol() async throws {
    let server = WhisperServer()
    try await server.start()
    let t = WhisperServerTranscriber(server: server)
    let samples = try sayToSamples("La reunión es el miércoles a las tres de la tarde.")
    let text = try await t.transcribe(samples, sampleRate: 16000, prompt: PersonalDictionary.default.whisperPrompt)
    await server.stop()
    #expect(text.lowercased().contains("miércoles"))
  }

  @Test(.enabled(if: FileManager.default.fileExists(atPath: WhisperServer.defaultModelPath)))
  func serverCaidoSeRecupera() async throws {
    let server = WhisperServer()
    try await server.start()
    await server.stop()
    let t = WhisperServerTranscriber(server: server)
    let samples = try sayToSamples("Hola, esto es una prueba.")
    let text = try await t.transcribe(samples, sampleRate: 16000, prompt: "")
    await server.stop()
    #expect(text.lowercased().contains("prueba"))
  }
}
