import Foundation

public protocol Transcriber: Sendable {
  func transcribe(_ samples: [Float], sampleRate: Int, prompt: String) async throws -> String
  /// Para audio difícil (reuniones, clases): sin arrastrar contexto, con varias hipótesis y sin tokens de no-voz.
  func transcribeRobust(_ samples: [Float], sampleRate: Int, prompt: String) async throws -> String
}

extension Transcriber {
  public func transcribeRobust(_ samples: [Float], sampleRate: Int, prompt: String) async throws -> String {
    try await transcribe(samples, sampleRate: sampleRate, prompt: prompt)
  }
}

public final class WhisperServerTranscriber: Transcriber {
  private let server: WhisperServer

  public init(server: WhisperServer) {
    self.server = server
  }

  public func transcribeRobust(_ samples: [Float], sampleRate: Int, prompt: String) async throws -> String {
    let extra = ["max_context": "0", "beam_size": "5", "best_of": "5", "suppress_nst": "true", "temperature_inc": "0.2"]
    do {
      return try await request(samples, sampleRate: sampleRate, prompt: prompt, extra: extra, timeout: 90)
    } catch {
      try await server.restart()
      return try await request(samples, sampleRate: sampleRate, prompt: prompt, extra: extra, timeout: 90)
    }
  }

  public func transcribe(_ samples: [Float], sampleRate: Int, prompt: String) async throws -> String {
    do {
      return try await request(samples, sampleRate: sampleRate, prompt: prompt)
    } catch {
      // Un reintento con el servidor reiniciado: si murió, esto lo recupera.
      try await server.restart()
      return try await request(samples, sampleRate: sampleRate, prompt: prompt)
    }
  }

  private func request(_ samples: [Float], sampleRate: Int, prompt: String,
                       extra: [String: String] = [:], timeout: TimeInterval = 20) async throws -> String {
    if !(await server.isAlive) { try await server.start() }
    let url = await server.baseURL.appendingPathComponent("inference")
    let boundary = "dicta-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(WAVEncoder.encode(samples: samples, sampleRate: sampleRate))
    body.append(Data("\r\n".utf8))
    field("language", "es")
    field("response_format", "json")
    field("temperature", "0")
    field("prompt", prompt)
    for (k, v) in extra.sorted(by: { $0.key < $1.key }) { field(k, v) }
    body.append(Data("--\(boundary)--\r\n".utf8))
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = timeout
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await URLSession.shared.upload(for: req, from: body)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = json["text"] as? String
    else { throw DictaError.transcriptionFailed("respuesta inválida del motor") }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
