import Foundation

/// Guarda el audio y el texto de los últimos dictados en ~/Library/Application Support/Faro/dictados, solo en este Mac,
/// para revisar con la voz real por qué un dictado salió mal. Cada dictado es un .wav (16 kHz) y un .txt con el
/// micrófono, lo que transcribió Whisper y lo que se pegó. Se conservan los últimos `limit`.
enum DictationArchive {
  static let limit = 30
  static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Faro/dictados")
  private static let queue = DispatchQueue(label: "faro.dictados", qos: .utility)

  /// Guarda el audio y devuelve el nombre base para agregarle el texto después.
  static func saveAudio(_ wav: Data, info: String) -> URL {
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let base = folder.appendingPathComponent(stamp.string(from: Date()))
    queue.async {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try? wav.write(to: base.appendingPathExtension("wav"))
      try? (info + "\n").write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
      prune()
    }
    return base
  }

  /// Agrega una línea al .txt del dictado (la transcripción, el texto final o por qué se descartó).
  static func note(_ line: String, to base: URL) {
    queue.async {
      let url = base.appendingPathExtension("txt")
      guard let h = try? FileHandle(forWritingTo: url) else { return }
      h.seekToEndOfFile()
      h.write(Data((line + "\n").utf8))
      try? h.close()
    }
  }

  private static func prune() {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let bases = Set(files.map { $0.deletingPathExtension().lastPathComponent }).sorted()
    for old in bases.dropLast(limit) {
      for ext in ["wav", "txt"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old).appendingPathExtension(ext)) }
    }
  }
}
