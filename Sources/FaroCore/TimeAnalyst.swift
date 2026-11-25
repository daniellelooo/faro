import Foundation

/// Resumen de un día escrito por Claude: qué se hizo, qué quedó pendiente y una línea de balance.
public struct DaySummary: Codable, Sendable, Equatable {
  public struct Pending: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id = UUID()
    public var project: String
    public var text: String
    public var done = false

    public init(project: String, text: String, done: Bool = false) {
      self.project = project
      self.text = text
      self.done = done
    }

    enum CodingKeys: String, CodingKey { case id, project = "proyecto", text = "texto", done = "hecho" }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
      project = try c.decode(String.self, forKey: .project)
      text = try c.decode(String.self, forKey: .text)
      done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }
  }

  public var summary: String
  public var pending: [Pending]
  public var verdict: String
  public var createdAt: Date

  public init(summary: String, pending: [Pending], verdict: String, createdAt: Date = Date()) {
    self.summary = summary
    self.pending = pending
    self.verdict = verdict
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey { case summary = "resumen", pending = "pendientes", verdict = "balance", createdAt = "creado" }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    summary = try c.decode(String.self, forKey: .summary)
    pending = try c.decode([Pending].self, forKey: .pending)
    verdict = (try? c.decode(String.self, forKey: .verdict)) ?? ""
    createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
  }
}

/// Lo que se le cuenta a Claude de un día, además de los tramos.
public struct DayContext: Sendable {
  /// Pendientes que venían del día anterior y no se marcaron como hechos.
  public var carriedPending: [DaySummary.Pending]
  /// Estado de los repositorios ("Tienda: 3 archivos sin commit en la rama pagos").
  public var repos: [String]
  /// Reuniones del día con sus pendientes.
  public var meetings: [String]
  /// Promedio de trabajo de los días anteriores con registro, para dar contexto al balance.
  public var averageWork: TimeInterval?

  public init(carriedPending: [DaySummary.Pending] = [], repos: [String] = [], meetings: [String] = [], averageWork: TimeInterval? = nil) {
    self.carriedPending = carriedPending
    self.repos = repos
    self.meetings = meetings
    self.averageWork = averageWork
  }
}

/// Le pide a Claude Haiku el resumen de un día y el análisis de una semana a partir del registro de tiempo.
/// Solo viajan títulos de ventanas, dominios y tiempos: nunca capturas de pantalla ni el contenido de las páginas.
public final class TimeAnalyst: Sendable {
  public static let model = "claude-haiku-5-5"
  private let apiKey: String?
  private let session: URLSession

  public init(apiKey: String?, session: URLSession? = nil) {
    self.apiKey = apiKey
    if let session {
      self.session = session
    } else {
      let c = URLSessionConfiguration.ephemeral
      c.timeoutIntervalForRequest = 120
      self.session = URLSession(configuration: c)
    }
  }

  static let daySystem = """
  Eres el registro de tiempo de una persona que trabaja en su computador (desarrollo de software, su agencia y sus productos).
  Recibes cómo repartió un día: horas por proyecto, las ventanas, páginas y chats de Claude Code donde pasó más tiempo, el estado de sus repositorios y sus reuniones.
  Escribe en español, en segunda persona ("trabajaste", "dejaste"), claro y concreto. No inventes nada que no esté en los datos.
  - resumen: 2 a 4 frases sobre en qué se fue el día: qué proyectos y qué cosas concretas (usa los títulos de los chats y ventanas para decir qué se hizo).
  - pendientes: cosas concretas que quedaron abiertas y conviene retomar mañana, con su proyecto. Salen de: cambios sin commit, pendientes de reuniones, pendientes del día anterior que siguen sin hacerse, y trabajo que se ve a medias. Máximo 6. Vacío si no hay nada claro.
  - balance: una sola frase honesta sobre si fue un día productivo, comparando las horas de trabajo con el promedio si se da, y nombrando el proyecto que quedó de lado si alguno importante no aparece.
  """

  static let weekSystem = """
  Eres el registro de tiempo de una persona que trabaja en su computador. Recibes sus últimos días: horas de trabajo y ocio por día, horas por proyecto y el resumen de cada día.
  Escribe en español, en segunda persona, directo y sin rodeos. No inventes nada que no esté en los datos.
  - analisis: 1 o 2 párrafos: cómo estuvo la semana, qué días rindieron y cuáles no, a qué proyectos se fue el tiempo y cuáles quedaron abandonados.
  - recomendaciones: 2 a 4 acciones concretas para los próximos días, basadas en lo que se ve (por ejemplo, retomar un proyecto concreto con una tarea concreta).
  """

  static var daySchema: [String: Any] {
    let pending: [String: Any] = [
      "type": "object",
      "properties": ["proyecto": ["type": "string"], "texto": ["type": "string"]],
      "required": ["proyecto", "texto"], "additionalProperties": false,
    ]
    return [
      "type": "object",
      "properties": ["resumen": ["type": "string"], "pendientes": ["type": "array", "items": pending], "balance": ["type": "string"]],
      "required": ["resumen", "pendientes", "balance"], "additionalProperties": false,
    ]
  }

  static var weekSchema: [String: Any] {
    [
      "type": "object",
      "properties": ["analisis": ["type": "string"], "recomendaciones": ["type": "array", "items": ["type": "string"]]],
      "required": ["analisis", "recomendaciones"], "additionalProperties": false,
    ]
  }

  /// El día contado en texto, para el modelo.
  public static func describe(day: String, spans raw: [ActivitySpan], context: DayContext = DayContext()) -> String {
    // Segunda barrera: aunque un registro viejo tuviera algo privado, no sale del Mac.
    let spans = raw.map { ActivityPrivacy.sanitize($0) }
    let totals = ActivityTotals(spans)
    let f = { (d: Date?) in d.map { $0.formatted(date: .omitted, time: .shortened) } ?? "?" }
    var out = "<dia fecha=\"\(day)\">\n"
    out += "Trabajo: \(ActivityTotals.format(totals.work)) · Ocio: \(ActivityTotals.format(totals.leisure)) · de \(f(totals.first)) a \(f(totals.last))\n"
    if let avg = context.averageWork { out += "Promedio de trabajo de los días anteriores: \(ActivityTotals.format(avg))\n" }
    out += "Por proyecto:\n"
    for p in totals.byProject where p.seconds >= 60 {
      out += "- \(p.name.isEmpty ? "Sin proyecto" : p.name): \(ActivityTotals.format(p.seconds))\n"
      let items = ActivityDetail.topItems(spans.filter { $0.kind == .work && ($0.project ?? "") == p.name }, limit: 8)
      for i in items where i.seconds >= 60 { out += "    · \(i.text) (\(ActivityTotals.format(i.seconds)))\n" }
    }
    let leisure = ActivityDetail.topItems(spans.filter { $0.kind == .leisure }, limit: 4)
    if !leisure.isEmpty {
      out += "Ocio:\n" + leisure.map { "    · \($0.text) (\(ActivityTotals.format($0.seconds)))" }.joined(separator: "\n") + "\n"
    }
    out += "</dia>\n"
    if !context.carriedPending.isEmpty {
      out += "<pendientes_del_dia_anterior>\n" + context.carriedPending.map { "- [\($0.project)] \($0.text)" }.joined(separator: "\n")
        + "\n</pendientes_del_dia_anterior>\n"
    }
    if !context.repos.isEmpty { out += "<repositorios>\n" + context.repos.map { "- \($0)" }.joined(separator: "\n") + "\n</repositorios>\n" }
    if !context.meetings.isEmpty { out += "<reuniones>\n" + context.meetings.joined(separator: "\n") + "\n</reuniones>\n" }
    return out
  }

  public struct WeekAnalysis: Codable, Sendable, Equatable {
    public var analysis: String
    public var recommendations: [String]
    public var createdAt = Date()
    enum CodingKeys: String, CodingKey { case analysis = "analisis", recommendations = "recomendaciones" }
  }

  public enum Failure: LocalizedError {
    case noKey, http(Int), unreadable
    public var errorDescription: String? {
      switch self {
      case .noKey: return "Falta la clave de API de Anthropic (Ajustes > Limpieza con Claude)."
      case .http(let s): return s == 401 ? "La clave de API no es válida o venció." : "La API respondió con un error (\(s))."
      case .unreadable: return "No se pudo leer la respuesta."
      }
    }
  }

  public func summarizeDay(_ description: String) async throws -> DaySummary {
    let text = try await ask(system: Self.daySystem, schema: Self.daySchema, content: description)
    return try JSONDecoder().decode(DaySummary.self, from: Data(text.utf8))
  }

  public func analyzeWeek(_ description: String) async throws -> WeekAnalysis {
    let text = try await ask(system: Self.weekSystem, schema: Self.weekSchema, content: description)
    return try JSONDecoder().decode(WeekAnalysis.self, from: Data(text.utf8))
  }

  func makeRequest(system: String, schema: [String: Any], content: String) throws -> URLRequest {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let body: [String: Any] = [
      "model": Self.model, "max_tokens": 2000, "system": system,
      "output_config": ["format": ["type": "json_schema", "schema": schema]],
      "messages": [["role": "user", "content": content]],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    return req
  }

  private func ask(system: String, schema: [String: Any], content: String) async throws -> String {
    guard let apiKey, !apiKey.isEmpty else { throw Failure.noKey }
    let (data, response) = try await session.data(for: try makeRequest(system: system, schema: schema, content: content))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw Failure.http(status) }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let blocks = json["content"] as? [[String: Any]],
      let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    else { throw Failure.unreadable }
    return text
  }
}
