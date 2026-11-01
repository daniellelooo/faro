import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable, Identifiable {
  public var id = UUID()
  /// Segundos desde el inicio de la reunión.
  public var start: Double
  public var end: Double
  public var text: String

  public init(start: Double, end: Double, text: String) {
    self.start = start
    self.end = end
    self.text = text
  }

  enum CodingKeys: String, CodingKey { case start, end, text }
}

public struct MeetingTask: Codable, Equatable, Sendable, Identifiable {
  public var id: String { description + (owner ?? "") }
  public var description: String
  public var owner: String?
  public var due: String?
  public var done: Bool = false

  enum CodingKeys: String, CodingKey {
    case description = "descripcion", owner = "responsable", due = "fecha", done = "hecha"
  }

  public init(description: String, owner: String?, due: String?, done: Bool = false) {
    self.description = description
    self.owner = owner
    self.due = due
    self.done = done
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    description = try c.decode(String.self, forKey: .description)
    owner = try c.decodeIfPresent(String.self, forKey: .owner).flatMap { $0.isEmpty ? nil : $0 }
    due = try c.decodeIfPresent(String.self, forKey: .due).flatMap { $0.isEmpty ? nil : $0 }
    done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
  }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
  public var title: String
  public var summary: String
  public var keyPoints: [String]
  public var decisions: [String]
  public var tasks: [MeetingTask]
  public var openQuestions: [String]

  enum CodingKeys: String, CodingKey {
    case title = "titulo", summary = "resumen", keyPoints = "puntos_clave", decisions = "decisiones",
      tasks = "tareas", openQuestions = "pendientes"
  }

  public init(title: String, summary: String, keyPoints: [String], decisions: [String], tasks: [MeetingTask], openQuestions: [String]) {
    self.title = title
    self.summary = summary
    self.keyPoints = keyPoints
    self.decisions = decisions
    self.tasks = tasks
    self.openQuestions = openQuestions
  }

  public static func decode(_ data: Data) throws -> MeetingSummary {
    try JSONDecoder().decode(MeetingSummary.self, from: data)
  }
}

public struct Meeting: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case recording, transcribing, summarizing, ready, interrupted, failed
  }

  public var id = UUID()
  public var startedAt: Date
  public var duration: Double = 0
  public var status: Status = .recording
  public var includesSystemAudio: Bool
  public var segments: [TranscriptSegment] = []
  public var summary: MeetingSummary?
  public var error: String?
  /// Grupo al que pertenece (por ejemplo, una materia: "Visualización de datos"). nil = sin grupo.
  public var group: String?

  public init(startedAt: Date, includesSystemAudio: Bool, summary: MeetingSummary? = nil) {
    self.startedAt = startedAt
    self.includesSystemAudio = includesSystemAudio
    self.summary = summary
  }

  public var displayTitle: String {
    summary?.title ?? "Reunión del \(startedAt.formatted(date: .abbreviated, time: .shortened))"
  }

  public var transcript: String { MeetingExport.timestamped(segments) }
}

/// Reuniones agrupadas para la lista: los grupos ordenados por su grabación más reciente, y al final las sueltas.
public enum MeetingGroups {
  public struct Section: Equatable, Sendable, Identifiable {
    public var id: String { name ?? "" }
    public var name: String?
    public var meetings: [Meeting]
  }

  public static func sections(_ meetings: [Meeting]) -> [Section] {
    var byName: [String: [Meeting]] = [:]
    var loose: [Meeting] = []
    for m in meetings {
      if let g = normalized(m.group) { byName[g, default: []].append(m) } else { loose.append(m) }
    }
    var out = byName.map { Section(name: $0.key, meetings: $0.value.sorted { $0.startedAt > $1.startedAt }) }
      .sorted { ($0.meetings.first?.startedAt ?? .distantPast) > ($1.meetings.first?.startedAt ?? .distantPast) }
    if !loose.isEmpty { out.append(Section(name: nil, meetings: loose.sorted { $0.startedAt > $1.startedAt })) }
    return out
  }

  /// Nombres de grupo existentes, sin repetir (sin importar mayúsculas), del más reciente al más viejo.
  public static func names(_ meetings: [Meeting]) -> [String] {
    sections(meetings).compactMap(\.name)
  }

  /// Quita espacios sobrantes; vacío = sin grupo.
  public static func normalized(_ name: String?) -> String? {
    guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
    return n
  }
}
