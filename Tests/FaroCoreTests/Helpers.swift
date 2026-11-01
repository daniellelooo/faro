import Foundation
@testable import FaroCore

/// Genera audio en español con la voz del Mac y lo devuelve como muestras de 16 kHz mono.
func sayToSamples(_ text: String, voice: String = "Eddy (Español (México))") throws -> [Float] {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dicta-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let aiff = dir.appendingPathComponent("a.aiff").path
  let raw = dir.appendingPathComponent("a.f32").path
  try run("/usr/bin/say", ["-v", voice, "-o", aiff, text])
  try run("/opt/homebrew/bin/ffmpeg", ["-loglevel", "error", "-y", "-i", aiff, "-ar", "16000", "-ac", "1", "-f", "f32le", raw])
  let data = try Data(contentsOf: URL(fileURLWithPath: raw))
  return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func run(_ exe: String, _ args: [String]) throws {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: exe)
  p.arguments = args
  try p.run()
  p.waitUntilExit()
  if p.terminationStatus != 0 { throw NSError(domain: "run", code: Int(p.terminationStatus)) }
}

/// URLProtocol que responde lo que diga `handler`, para probar el limpiador sin red.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
  nonisolated(unsafe) static var lastBody: Data?
  /// Demora simulada por petición, sin bloquear el hilo de carga.
  nonisolated(unsafe) static var delay: ((Int) -> TimeInterval)?
  nonisolated(unsafe) static var requestCount = 0
  /// Respuesta según el número de petición (1, 2…); tiene prioridad sobre `handler`.
  nonisolated(unsafe) static var perRequest: ((Int) -> (Int, Data))?
  private var stopped = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody
    if body == nil, let stream = request.httpBodyStream {
      stream.open()
      var d = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        d.append(buf, count: n)
      }
      stream.close()
      body = d
    }
    Self.lastBody = body
    Self.requestCount += 1
    let number = Self.requestCount
    let wait = Self.delay?(number) ?? 0
    let respond = { [self] in
      if stopped { return }
      do {
        let (status, data) = try Self.perRequest.map { $0(number) } ?? Self.handler!(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
    if wait > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + wait, execute: respond) } else { respond() }
  }
  override func stopLoading() { stopped = true }

  static func session() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: c)
  }
}
