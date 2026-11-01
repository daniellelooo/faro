import Foundation

/// Respuesta del copiloto a una pregunta hecha en la reunión.
public struct CopilotAnswer: Codable, Equatable, Sendable, Identifiable {
  public var id = UUID()
  public var question: String
  public var answer: String
  /// false si la ficha no cubría la pregunta (la respuesta es una salida honesta, no un dato).
  public var inNotes: Bool
  public var at: Date

  public init(question: String, answer: String, inNotes: Bool, at: Date = Date()) {
    self.question = question
    self.answer = answer
    self.inNotes = inNotes
    self.at = at
  }
}

/// Copiloto de reuniones: mira el último minuto de la transcripción en vivo y, si alguien preguntó algo que las notas
/// de contexto del usuario cubren, responde en 2-3 líneas usando solo esas notas (fichas). Las fichas van en el prompt con caché
/// (se mandan una vez cada 5 minutos, no en cada llamada). Las llamadas van de a una: si llega otro tramo mientras
/// piensa, al terminar mira solo lo más nuevo.
public actor MeetingCopilot {
  public static let model = "claude-haiku-5-5"
  /// Carpeta por defecto de las notas de contexto (un .md por tema). Se cambia en Ajustes; se leen todas al empezar
  /// cada reunión.
  public static var defaultFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Faro/Notas")
  }

  /// Carpeta configurada en Ajustes: una ruta vacía desactiva el copiloto; `~` se expande.
  public static func folder(fromSetting path: String) -> URL? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
  }
  /// Segundos de conversación que se le muestran al modelo.
  public static let window = 75.0

  private let apiKey: String
  private let knowledge: String
  private let session: URLSession
  private var answered: [CopilotAnswer] = []
  private var busy = false
  private var pending: [TranscriptSegment]?
  /// Fin del último tramo ya revisado: un tramo se revisa una sola vez.
  private var lastSeenEnd = -1.0

  public init(apiKey: String, knowledge: String, session: URLSession? = nil) {
    self.apiKey = apiKey
    self.knowledge = knowledge
    if let session {
      self.session = session
    } else {
      let c = URLSessionConfiguration.ephemeral
      c.timeoutIntervalForRequest = 15
      self.session = URLSession(configuration: c)
    }
  }

  /// Junta las fichas .md de la carpeta, cada una con su nombre. Vacío si no hay ninguna.
  public static func loadKnowledge(from folder: URL = defaultFolder) -> (text: String, names: [String]) {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let notes = files.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var parts: [String] = []
    var names: [String] = []
    for url in notes {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      let name = url.deletingPathExtension().lastPathComponent
      names.append(name)
      parts.append("<ficha nombre=\"\(name)\">\n\(text)\n</ficha>")
    }
    return (parts.joined(separator: "\n\n"), names)
  }

  /// Le pasa al copiloto la transcripción hasta ahora. Devuelve las respuestas nuevas (casi siempre ninguna o una).
  public func consider(_ segments: [TranscriptSegment]) async -> [CopilotAnswer] {
    if busy {
      pending = segments
      return []
    }
    busy = true
    defer { busy = false }
    var current = segments
    var result: [CopilotAnswer] = []
    while true {
      if let a = await evaluate(current) { result.append(a) }
      guard let next = pending else { break }
      pending = nil
      current = next
    }
    return result
  }

  public var history: [CopilotAnswer] { answered }

  private func evaluate(_ segments: [TranscriptSegment]) async -> CopilotAnswer? {
    guard let last = segments.last, last.end > lastSeenEnd else { return nil }
    lastSeenEnd = last.end
    let recent = Self.recent(segments)
    guard Self.wordCount(recent.last?.text ?? "") >= 3 else { return nil }
    guard let req = try? makeRequest(recent: recent),
      let (data, response) = try? await session.data(for: req),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    if ProcessInfo.processInfo.environment["COPILOTO_DEBUG"] != nil { print("COPILOTO:", String(decoding: data, as: UTF8.self)) }
    guard let decision = Self.parse(data) else { return nil }
    guard decision.hasQuestion, !decision.answer.isEmpty, !isRepeat(decision.question) else { return nil }
    let a = CopilotAnswer(question: decision.question, answer: decision.answer, inNotes: decision.inNotes)
    answered.append(a)
    return a
  }

  /// La misma pregunta dicha dos veces (o reformulada casi igual) no se vuelve a responder.
  func isRepeat(_ question: String) -> Bool {
    let q = Self.words(question)
    guard !q.isEmpty else { return true }
    return answered.suffix(8).contains { prev in
      let p = Self.words(prev.question)
      let shared = Double(q.intersection(p).count)
      return shared / Double(max(1, min(q.count, p.count))) >= 0.8
    }
  }

  static func words(_ s: String) -> Set<String> {
    Set(s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 })
  }

  static func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

  /// Los tramos del último minuto y algo, para que una pregunta partida en dos tramos llegue entera.
  static func recent(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
    guard let end = segments.last?.end else { return [] }
    return segments.filter { $0.end >= end - window }
  }

  static let system = """
  Eres el apoyo silencioso del usuario durante una reunión en vivo. Recibes el último minuto de la transcripción \
  automática (en español, con errores de reconocimiento, sin separar quién habla) y las fichas: notas de contexto \
  que el usuario escribió sobre su trabajo, sus productos o sus proyectos. Tu respuesta aparece en la pantalla del \
  usuario para que la diga con sus palabras.

  Decide si en el TRAMO MÁS RECIENTE (o terminando en él) alguien le hizo al usuario una pregunta o le pidió una \
  explicación sobre algo que las fichas tratan (por ejemplo tecnología, arquitectura, seguridad, datos, \
  integraciones, precio, plazos, soporte o forma de trabajo). Si es así, hay_pregunta = true.

  hay_pregunta = false cuando: es charla o saludo; la pregunta la hace el usuario a los demás (sobre sus asuntos); \
  ya está en la lista de respuestas dadas; el usuario ya la respondió bien en la transcripción; o el tramo está \
  incompleto y todavía no se entiende qué preguntan.

  Si hay pregunta:
  - pregunta: la pregunta reformulada, clara, en máximo 12 palabras.
  - respuesta: lo que el usuario va a leer de un vistazo mientras habla. Máximo 35 palabras, 1 o 2 frases, con el \
  dato concreto (tecnología, cifra, nombre). Empieza por la respuesta, sin introducción. Responde SOLO esa \
  pregunta: no repitas lo que ya se respondió antes.
  - Usa SOLO lo que dicen las fichas. Nunca inventes cifras, certificaciones, clientes ni funciones, y respeta lo \
  que las fichas marcan como no implementado o no verificado.
  - en_la_ficha = false si las fichas no cubren la pregunta; entonces la respuesta es una salida honesta (por \
  ejemplo, que lo confirma y lo envía por escrito) más lo más cercano que sí digan las fichas, si hay algo.
  Si no hay pregunta, deja pregunta y respuesta vacías.
  """

  static var schema: [String: Any] {
    [
      "type": "object",
      "properties": [
        "hay_pregunta": ["type": "boolean"], "pregunta": ["type": "string"],
        "respuesta": ["type": "string"], "en_la_ficha": ["type": "boolean"],
      ],
      "required": ["hay_pregunta", "pregunta", "respuesta", "en_la_ficha"],
      "additionalProperties": false,
    ]
  }

  func makeRequest(recent: [TranscriptSegment]) throws -> URLRequest {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let body: [String: Any] = [
      "model": Self.model,
      "max_tokens": 700,
      // Sin razonamiento previo: responde más rápido y no se come el cupo de tokens antes del JSON.
      "thinking": ["type": "disabled"],
      // Las fichas van al final del system con caché: son lo largo y no cambian durante la reunión.
      "system": [
        ["type": "text", "text": Self.system],
        ["type": "text", "text": "<fichas>\n\(knowledge)\n</fichas>", "cache_control": ["type": "ephemeral"]],
      ],
      "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
      "messages": [["role": "user", "content": userContent(recent: recent)]],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    return req
  }

  func userContent(recent: [TranscriptSegment]) -> String {
    let given = answered.suffix(10).map { "- \($0.question)" }.joined(separator: "\n")
    return """
    <respuestas_dadas>
    \(given.isEmpty ? "(ninguna todavía)" : given)
    </respuestas_dadas>
    <transcripcion_reciente>
    \(MeetingExport.timestamped(recent))
    </transcripcion_reciente>
    La última línea es el tramo más reciente.
    """
  }

  struct Decision: Decodable {
    var hasQuestion: Bool
    var question: String
    var answer: String
    var inNotes: Bool
    enum CodingKeys: String, CodingKey {
      case hasQuestion = "hay_pregunta", question = "pregunta", answer = "respuesta", inNotes = "en_la_ficha"
    }
  }

  static func parse(_ data: Data) -> Decision? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = json["content"] as? [[String: Any]],
      let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    else { return nil }
    return try? JSONDecoder().decode(Decision.self, from: Data(text.utf8))
  }
}
