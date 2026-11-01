import Foundation

/// Resume una reunión con Claude Haiku y salida JSON estructurada (resumen, decisiones, tareas, pendientes).
public final class MeetingSummarizer: Sendable {
  public static let model = "claude-haiku-5-5"
  private let apiKey: String?
  private let session: URLSession

  public init(apiKey: String?, session: URLSession? = nil) {
    self.apiKey = apiKey
    if let session {
      self.session = session
    } else {
      let c = URLSessionConfiguration.ephemeral
      c.timeoutIntervalForRequest = 180
      c.timeoutIntervalForResource = 300
      self.session = URLSession(configuration: c)
    }
  }

  static let system = """
  Resumes reuniones de trabajo a partir de su transcripción automática en español (tiene marcas de tiempo y errores de transcripción; no separa quién habla).
  Escribe en español claro y concreto. No inventes nada que no esté en la transcripción.
  - titulo: un título corto y específico (máximo 8 palabras), por ejemplo «Kickoff de la app de Kivo con el cliente».
  - resumen: 1 a 3 párrafos con lo esencial: contexto, qué se discutió y en qué quedó.
  - puntos_clave: las ideas o datos importantes (cifras, fechas, nombres), uno por elemento.
  - decisiones: lo que se decidió explícitamente. Vacío si no hubo decisiones.
  - tareas: compromisos concretos. "responsable" solo si se menciona quién (nombre o "yo" si el hablante se compromete); "fecha" solo si se menciona (tal como se dijo). Usa cadena vacía si no se sabe.
  - pendientes: preguntas abiertas o temas que quedaron sin resolver.
  Corrige en el resumen los nombres que la transcripción escribió mal cuando el contexto deje claro cuál es el correcto.
  """

  static var schema: [String: Any] {
    let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
    let task: [String: Any] = [
      "type": "object",
      "properties": ["descripcion": ["type": "string"], "responsable": ["type": "string"], "fecha": ["type": "string"]],
      "required": ["descripcion", "responsable", "fecha"],
      "additionalProperties": false,
    ]
    return [
      "type": "object",
      "properties": [
        "titulo": ["type": "string"], "resumen": ["type": "string"], "puntos_clave": strings,
        "decisiones": strings, "tareas": ["type": "array", "items": task], "pendientes": strings,
      ],
      "required": ["titulo", "resumen", "puntos_clave", "decisiones", "tareas", "pendientes"],
      "additionalProperties": false,
    ]
  }

  func makeRequest(transcript: String, vocabulary: [String] = []) throws -> URLRequest {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 180
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let body: [String: Any] = [
      "model": Self.model,
      "max_tokens": 8000,
      "system": Self.system,
      "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
      "messages": [["role": "user", "content": Self.userContent(transcript: transcript, vocabulary: vocabulary)]],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    return req
  }

  static func userContent(transcript: String, vocabulary: [String]) -> String {
    let vocab = vocabulary.isEmpty ? "" :
      "<vocabulario>\nNombres y términos que suelen aparecer (la transcripción puede escribirlos mal por sonido parecido): \(vocabulary.joined(separator: ", "))\n</vocabulario>\n"
    return vocab + "<transcripcion>\n\(transcript)\n</transcripcion>"
  }

  public enum Failure: LocalizedError {
    case noKey, http(Int), unreadable
    public var errorDescription: String? {
      switch self {
      case .noKey: return "Falta la clave de API de Anthropic para resumir."
      case .http(let s): return s == 401 ? "La clave de API no es válida." : "La API respondió con un error (\(s))."
      case .unreadable: return "No se pudo leer el resumen."
      }
    }
  }

  public func summarize(transcript: String, vocabulary: [String] = []) async throws -> MeetingSummary {
    guard let apiKey, !apiKey.isEmpty else { throw Failure.noKey }
    _ = apiKey
    let (data, response) = try await session.data(for: try makeRequest(transcript: transcript, vocabulary: vocabulary))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw Failure.http(status) }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = json["content"] as? [[String: Any]],
      let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    else { throw Failure.unreadable }
    return try MeetingSummary.decode(Data(text.utf8))
  }
}

public enum MeetingExport {
  public static func clock(_ s: Double) -> String {
    let t = Int(s)
    return t >= 3600
      ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
      : String(format: "%02d:%02d", t / 60, t % 60)
  }

  public static func timestamped(_ segments: [TranscriptSegment]) -> String {
    segments.map { "[\(clock($0.start))] \($0.text)" }.joined(separator: "\n")
  }

  public static func markdown(_ m: Meeting) -> String {
    var out = "# \(m.displayTitle)\n\n"
    out += "\(m.startedAt.formatted(date: .long, time: .shortened)) · \(clock(m.duration))\n\n"
    if let s = m.summary {
      out += "## Resumen\n\n\(s.summary)\n\n"
      if !s.keyPoints.isEmpty { out += "## Puntos clave\n\n" + s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
      if !s.decisions.isEmpty { out += "## Decisiones\n\n" + s.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
      if !s.tasks.isEmpty {
        out += "## Tareas\n\n" + s.tasks.map { t in
          let extra = [t.owner, t.due].compactMap { $0 }.joined(separator: ", ")
          return "- [\(t.done ? "x" : " ")] \(t.description)" + (extra.isEmpty ? "" : " (\(extra))")
        }.joined(separator: "\n") + "\n\n"
      }
      if !s.openQuestions.isEmpty { out += "## Pendientes\n\n" + s.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
    }
    if !m.segments.isEmpty { out += "## Transcripción\n\n" + timestamped(m.segments) + "\n" }
    return out
  }
}
