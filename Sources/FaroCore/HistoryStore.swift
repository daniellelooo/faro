import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
  public var id = UUID()
  public var date: Date
  public var raw: String
  public var final: String
  public var app: String
  public var usedFallback: Bool
  public var seconds: Double
  /// Campos agregados después: opcionales para poder leer historiales viejos.
  public var bundleID: String?
  /// nil = no se pudo comprobar; true = el texto apareció en el campo; false = el pegado falló.
  public var verified: Bool?
  public var tone: Tone?

  public init(date: Date, raw: String, final: String, app: String, usedFallback: Bool, seconds: Double,
              bundleID: String? = nil, verified: Bool? = nil, tone: Tone? = nil) {
    self.date = date
    self.raw = raw
    self.final = final
    self.app = app
    self.usedFallback = usedFallback
    self.seconds = seconds
    self.bundleID = bundleID
    self.verified = verified
    self.tone = tone
  }

  public var words: Int { TextNormalizer.normalize(final).count }
}

/// Números para la pantalla de inicio.
public struct HistoryStats: Sendable {
  public var wordsThisWeek = 0
  public var totalWords = 0
  public var dictationsThisWeek = 0
  public var averageSeconds = 0.0
  public var minutesSavedThisWeek = 0.0
  public static let typingWPM = 40.0
  public static let speakingWPM = 150.0

  public init(entries: [HistoryEntry], now: Date = Date()) {
    let weekAgo = now.addingTimeInterval(-7 * 86400)
    let week = entries.filter { $0.date >= weekAgo }
    wordsThisWeek = week.reduce(0) { $0 + $1.words }
    totalWords = entries.reduce(0) { $0 + $1.words }
    dictationsThisWeek = week.count
    averageSeconds = week.isEmpty ? 0 : week.reduce(0) { $0 + $1.seconds } / Double(week.count)
    let w = Double(wordsThisWeek)
    minutesSavedThisWeek = max(0, w / Self.typingWPM - w / Self.speakingWPM)
  }
}

/// Últimos 100 dictados, el más nuevo primero, en un JSON local.
public final class HistoryStore: @unchecked Sendable {
  public static let limit = 100
  public static var defaultFile: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Faro/historial.json")
  }

  public private(set) var entries: [HistoryEntry] = []
  private let file: URL
  private let lock = NSLock()

  public init(file: URL = HistoryStore.defaultFile) {
    self.file = file
    if let data = try? Data(contentsOf: file),
      let decoded = try? JSONDecoder.iso.decode([HistoryEntry].self, from: data)
    {
      entries = decoded
    }
  }

  public func add(_ entry: HistoryEntry) {
    lock.lock()
    entries.insert(entry, at: 0)
    if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    let snapshot = entries
    lock.unlock()
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder.iso.encode(snapshot).write(to: file, options: .atomic)
  }
}

extension JSONEncoder {
  static var iso: JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }
}

extension JSONDecoder {
  static var iso: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }
}
