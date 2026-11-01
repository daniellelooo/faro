import Foundation

/// Proceso hijo `whisper-server` con el modelo cargado en memoria, escuchando en 127.0.0.1.
public actor WhisperServer {
  public static let defaultBinary = "/opt/homebrew/bin/whisper-server"
  public static var defaultModelPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Faro/models/ggml-large-v3-turbo-q5_0.bin").path
  }

  private let binary: String
  private let modelPath: String
  private var process: Process?
  public private(set) var port: Int = 0

  public init(binary: String = WhisperServer.defaultBinary, modelPath: String = WhisperServer.defaultModelPath) {
    self.binary = binary
    self.modelPath = modelPath
  }

  public var isAlive: Bool { process?.isRunning ?? false }

  public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

  public func start() async throws {
    if isAlive { return }
    guard FileManager.default.isExecutableFile(atPath: binary) else { throw DictaError.whisperNotInstalled }
    guard FileManager.default.fileExists(atPath: modelPath) else { throw DictaError.modelMissing(modelPath) }
    Self.killStale(modelPath: modelPath)
    port = Self.freePort()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = ["-m", modelPath, "-l", "es", "--host", "127.0.0.1", "--port", String(port), "-t", "6"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    process = p
    // Espera a que el modelo cargue (unos segundos la primera vez).
    for _ in 0..<120 {
      if !p.isRunning { break }
      if await Self.responds(baseURL) { return }
      try? await Task.sleep(for: .milliseconds(250))
    }
    stop()
    throw DictaError.serverDidNotStart
  }

  public func stop() {
    process?.terminate()
    process = nil
  }

  public func restart() async throws {
    stop()
    try await start()
  }

  /// Cierra servidores que quedaron huérfanos de una instancia anterior de Faro (mismo modelo).
  static func killStale(modelPath: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-f", "whisper-server -m \(modelPath)"]
    try? p.run()
    p.waitUntilExit()
  }

  static func responds(_ url: URL) async -> Bool {
    var req = URLRequest(url: url)
    req.timeoutInterval = 1
    return (try? await URLSession.shared.data(for: req)) != nil
  }

  static func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return Int(UInt16(bigEndian: addr.sin_port))
  }
}
