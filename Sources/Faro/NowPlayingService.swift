import AppKit
import Observation
import SwiftUI

struct NowPlaying: Equatable {
  var title: String
  var artist: String
  var album: String
  var duration: Double
  var elapsed: Double
  var rate: Double
  var timestamp: Date?
  var playing: Bool
  var appBundleID: String?

  /// Posición actual estimada (la información solo llega al cambiar algo).
  func position(at now: Date = Date()) -> Double {
    guard playing, let timestamp else { return elapsed }
    return min(duration, elapsed + now.timeIntervalSince(timestamp) * (rate == 0 ? 1 : rate))
  }
}

/// Música que suena en el Mac (Spotify, Música, navegador…), vía el adaptador que corre dentro de /usr/bin/perl.
@MainActor @Observable
final class NowPlayingService {
  var current: NowPlaying?
  var artwork: NSImage? {
    didSet { accent = artwork.flatMap(Self.dominantColor) }
  }
  /// Color dominante de la carátula (tiñe las barras de música y el resplandor).
  var accent: Color?
  /// Se llama cuando empieza a sonar una canción distinta.
  @ObservationIgnored var onTrackChange: ((NowPlaying) -> Void)?

  private var process: Process?
  private var input: Pipe?
  private var buffer = Data()
  private var lastTrackKey = ""

  func start() {
    guard process == nil,
      let script = Bundle.main.url(forResource: "now-playing", withExtension: "pl"),
      let lib = Bundle.main.url(forResource: "libDictaNowPlaying", withExtension: "dylib")
    else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [script.path, lib.path, "watch"]
    let out = Pipe()
    let inp = Pipe()
    p.standardOutput = out
    p.standardInput = inp
    p.standardError = FileHandle.nullDevice
    out.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in self?.receive(data) }
    }
    p.terminationHandler = { [weak self] _ in
      // Si el adaptador se cae, se vuelve a lanzar.
      Task { @MainActor in
        self?.process = nil
        try? await Task.sleep(for: .seconds(2))
        self?.start()
      }
    }
    try? p.run()
    process = p
    input = inp
  }

  func stop() {
    process?.terminationHandler = nil
    process?.terminate()
    process = nil
  }

  func send(_ command: String) {
    input?.fileHandleForWriting.write(Data((command + "\n").utf8))
  }

  func togglePlayPause() { send("toggle") }

  // MARK: Aleatorio y repetición
  // Spotify y Música se manejan por AppleScript (la primera vez macOS pide permiso de Automatización); con el resto
  // se usa la orden de MediaRemote, que funciona en los reproductores que la aceptan.

  /// nil = no se sabe (el reproductor no lo dice).
  var shuffling: Bool?
  var repeating: Bool?

  private var scriptApp: String? {
    switch current?.appBundleID {
    case "com.spotify.client": return "Spotify"
    case "com.apple.Music": return "Music"
    default: return nil
    }
  }

  func refreshModes() {
    guard let app = scriptApp else {
      shuffling = nil
      repeating = nil
      return
    }
    let shuffleProp = app == "Spotify" ? "shuffling" : "shuffle enabled"
    let repeatProp = app == "Spotify" ? "repeating" : "(song repeat is not off)"
    shuffling = Self.runBool("tell application \"\(app)\" to get \(shuffleProp)")
    repeating = Self.runBool("tell application \"\(app)\" to get \(repeatProp)")
  }

  func toggleShuffle() {
    if let app = scriptApp {
      let prop = app == "Spotify" ? "shuffling" : "shuffle enabled"
      _ = Self.run("tell application \"\(app)\" to set \(prop) to not \(prop)")
      refreshModes()
    } else {
      send("shuffle")
      shuffling = shuffling.map { !$0 }
    }
  }

  func toggleRepeat() {
    if let app = scriptApp {
      if app == "Spotify" {
        _ = Self.run("tell application \"Spotify\" to set repeating to not repeating")
      } else {
        _ = Self.run("tell application \"Music\" to if song repeat is off then set song repeat to all else set song repeat to off")
      }
      refreshModes()
    } else {
      send("repeat")
      repeating = repeating.map { !$0 }
    }
  }

  private static func run(_ source: String) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    return NSAppleScript(source: source)?.executeAndReturnError(&error)
  }

  private static func runBool(_ source: String) -> Bool? {
    guard let d = run(source) else { return nil }
    return d.booleanValue
  }
  func next() { send("next") }
  func previous() { send("previous") }

  private func receive(_ data: Data) {
    buffer.append(data)
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<nl]
      buffer.removeSubrange(buffer.startIndex...nl)
      guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
      handle(o)
    }
  }

  private func handle(_ o: [String: Any]) {
    let playing = (o["playing"] as? NSNumber)?.boolValue ?? false
    guard let title = o["title"] as? String, !title.isEmpty else {
      current = nil
      artwork = nil
      return
    }
    if let b64 = o["artwork"] as? String, let d = Data(base64Encoded: b64) { artwork = NSImage(data: d) }
    if o["artworkId"] == nil { artwork = nil }
    let pid = (o["pid"] as? NSNumber)?.int32Value ?? 0
    let np = NowPlaying(
      title: title, artist: o["artist"] as? String ?? "", album: o["album"] as? String ?? "",
      duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0, elapsed: (o["elapsed"] as? NSNumber)?.doubleValue ?? 0,
      rate: (o["rate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0),
      timestamp: (o["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
      playing: playing, appBundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    let key = title + "|" + np.artist
    // En un navegador, pasar el puntero por un video (YouTube) lo reproduce como vista previa y el sistema lo reporta
    // como si sonara. Lo que suena en un navegador solo se muestra tras unos segundos seguidos sonando.
    if let id = np.appBundleID, PillVisibility.browsers.contains(id), key != confirmedBrowserKey {
      latestBrowser = np
      guard playing else { return }
      // Con la página activa en la portada, una búsqueda o un canal de YouTube, lo que suena es una vista previa
      // (empiezan a mitad del video y siguen mientras el puntero esté quieto encima de la miniatura).
      let url = PillVisibility.focusedPageURL(pid: pid)
      let preview = PillVisibility.isYouTubeBrowsing(url)
      Self.log("\(preview ? "vista previa" : "en espera") «\(title)» · pestaña «\(PillVisibility.focusedWindowTitle(pid: pid) ?? "?")» · \(url?.absoluteString ?? "sin dirección")")
      if preview { return }
      if pendingBrowserKey != key {
        pendingBrowserKey = key
        pendingBrowser?.cancel()
        pendingBrowser = Task { [weak self] in
          try? await Task.sleep(for: .seconds(Self.browserConfirmDelay))
          guard let self, !Task.isCancelled, self.pendingBrowserKey == key, let latest = self.latestBrowser,
            latest.playing, latest.title + "|" + latest.artist == key else { return }
          // Pudo cambiar de página en la espera (de un video a la portada): se vuelve a revisar.
          if PillVisibility.isYouTubeBrowsing(PillVisibility.focusedPageURL(pid: pid)) { return }
          Self.log("se muestra «\(latest.title)»")
          self.confirmedBrowserKey = key
          self.show(latest, key: key)
        }
      }
      return
    }
    show(np, key: key)
  }

  static let browserConfirmDelay = 4.0

  /// Registro de lo que suena en navegadores, para revisar casos raros (vistas previas, videos de otra pestaña).
  static func log(_ text: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Faro/musica-navegador.log")
    let line = "\(Date()) \(text)\n"
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile()
      h.write(Data(line.utf8))
      try? h.close()
    } else {
      try? line.write(to: url, atomically: true, encoding: .utf8)
    }
  }
  private var confirmedBrowserKey = ""
  private var pendingBrowserKey = ""
  private var pendingBrowser: Task<Void, Never>?
  private var latestBrowser: NowPlaying?

  private func show(_ np: NowPlaying, key: String) {
    let playing = np.playing
    current = np
    if key != lastTrackKey {
      lastTrackKey = key
      if playing { onTrackChange?(np) }
    }
  }

  /// Promedio de la carátula reducida a 8×8, aclarado para que se vea sobre negro.
  static func dominantColor(_ image: NSImage) -> Color? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let n = 8
    var pixels = [UInt8](repeating: 0, count: n * n * 4)
    guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
    var r = 0.0, g = 0.0, b = 0.0, count = 0.0
    for i in stride(from: 0, to: pixels.count, by: 4) {
      let pr = Double(pixels[i]), pg = Double(pixels[i + 1]), pb = Double(pixels[i + 2])
      // Se ignoran píxeles casi negros o casi blancos: no dicen nada del color.
      let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
      if mx < 30 || mn > 235 { continue }
      r += pr; g += pg; b += pb; count += 1
    }
    guard count > 0 else { return nil }
    let c = NSColor(red: r / count / 255, green: g / count / 255, blue: b / count / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
    return Color(hue: h, saturation: min(1, s * 1.2), brightness: max(0.75, v))
  }
}
