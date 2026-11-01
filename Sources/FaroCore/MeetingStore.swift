import Foundation

/// Reuniones en disco: una carpeta por reunión con `reunion.json` y el audio (`audio.aac`; las viejas, `audio.m4a`).
public final class MeetingStore: @unchecked Sendable {
  public static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Faro/reuniones")
  }

  public let root: URL
  public init(root: URL = MeetingStore.defaultRoot) {
    self.root = root
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  public func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
  /// El audio existente de la reunión (o dónde grabarlo si todavía no hay).
  public func audioURL(_ id: UUID) -> URL {
    let legacy = folder(id).appendingPathComponent("audio.m4a")
    return FileManager.default.fileExists(atPath: legacy.path) ? legacy : recordingURL(id)
  }

  /// Las grabaciones nuevas van en AAC con encabezados ADTS: cada trozo se puede leer por sí solo, así que un cierre
  /// forzado o un apagón no dañan el archivo (un .m4a sin cerrar queda ilegible porque su índice se escribe al final).
  public func recordingURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("audio.aac") }

  public func save(_ m: Meeting) throws {
    try FileManager.default.createDirectory(at: folder(m.id), withIntermediateDirectories: true)
    try JSONEncoder.iso.encode(m).write(to: folder(m.id).appendingPathComponent("reunion.json"), options: .atomic)
  }

  public func load(_ id: UUID) -> Meeting? {
    guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("reunion.json")) else { return nil }
    return try? JSONDecoder.iso.decode(Meeting.self, from: data)
  }

  /// La más reciente primero.
  public func list() -> [Meeting] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.compactMap { UUID(uuidString: $0.lastPathComponent).flatMap(load) }.sorted { $0.startedAt > $1.startedAt }
  }

  public func delete(_ id: UUID) throws {
    try FileManager.default.removeItem(at: folder(id))
  }

  /// Reuniones que quedaron a medias porque Faro se cerró: se marcan como interrumpidas. Devuelve cuántas.
  @discardableResult
  public func recoverInterrupted() -> Int {
    var n = 0
    for var m in list() where [.recording, .transcribing, .summarizing].contains(m.status) {
      m.status = .interrupted
      if let last = m.segments.last { m.duration = max(m.duration, last.end) }
      try? save(m)
      n += 1
    }
    return n
  }
}
