import Foundation

public struct CleanResult: Sendable, Equatable {
  public var text: String
  public var usedFallback: Bool
  public var reason: String?

  public init(text: String, usedFallback: Bool, reason: String? = nil) {
    self.text = text
    self.usedFallback = usedFallback
    self.reason = reason
  }
}

public protocol Cleaner: Sendable {
  /// Nunca falla: ante cualquier error devuelve el texto crudo con `usedFallback = true`.
  func clean(_ raw: String, tone: Tone, dictionary: PersonalDictionary, context: ScreenContext?) async -> CleanResult
}

extension Cleaner {
  public func clean(_ raw: String, tone: Tone, dictionary: PersonalDictionary) async -> CleanResult {
    await clean(raw, tone: tone, dictionary: dictionary, context: nil)
  }
}

/// Limpieza con Claude Haiku por la API de Messages (HTTP directo: Swift no tiene SDK oficial).
public final class AnthropicCleaner: Cleaner {
  public static let model = "claude-haiku-5-5"
  private let apiKey: String?
  private let session: URLSession
  private let timeout: TimeInterval

  public init(apiKey: String?, session: URLSession? = nil, timeout: TimeInterval = 3) {
    self.apiKey = apiKey
    self.timeout = timeout
    if let session {
      self.session = session
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = timeout
      config.timeoutIntervalForResource = timeout
      self.session = URLSession(configuration: config)
    }
  }

  func makeRequest(_ raw: String, tone: Tone, dictionary: PersonalDictionary, context: ScreenContext? = nil) throws -> URLRequest {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.timeoutInterval = timeout
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let body: [String: Any] = [
      "model": Self.model,
      "max_tokens": 2048,
      "thinking": ["type": "disabled"],
      "output_config": ["effort": "low"],
      "system": CleanupPrompt.system(tone: tone, dictionary: dictionary),
      "messages": [["role": "user", "content": CleanupPrompt.user(raw: raw, context: context)]],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    return req
  }

  /// Si la primera petición no responde en este tiempo, se lanza una segunda igual y gana la primera que llegue.
  public static let hedgeDelay: TimeInterval = 1.1

  public func clean(_ raw: String, tone: Tone, dictionary: PersonalDictionary, context: ScreenContext?) async -> CleanResult {
    guard let apiKey, !apiKey.isEmpty else {
      return CleanResult(text: raw, usedFallback: true, reason: "Sin clave de API")
    }
    _ = apiKey
    guard let req = try? makeRequest(raw, tone: tone, dictionary: dictionary, context: context) else {
      return CleanResult(text: raw, usedFallback: true, reason: "Petición inválida")
    }
    let deadline = Date().addingTimeInterval(timeout)
    return await withTaskGroup(of: CleanResult?.self) { group in
      group.addTask { await self.attempt(req, raw: raw, deadline: deadline) }
      group.addTask {
        try? await Task.sleep(for: .seconds(Self.hedgeDelay))
        if Task.isCancelled || Date() >= deadline { return nil }
        return await self.attempt(req, raw: raw, deadline: deadline)
      }
      var firstFailure: CleanResult?
      for await result in group {
        guard let result else { continue }
        if !result.usedFallback {
          group.cancelAll()
          return result
        }
        // Si una falla, se espera a la otra: puede seguir en camino y llegar bien.
        if firstFailure == nil { firstFailure = result }
      }
      return firstFailure ?? CleanResult(text: raw, usedFallback: true, reason: "La limpieza tardó demasiado")
    }
  }

  private func attempt(_ base: URLRequest, raw: String, deadline: Date) async -> CleanResult {
    var req = base
    req.timeoutInterval = max(0.3, deadline.timeIntervalSinceNow)
    do {
      let (data, response) = try await session.data(for: req)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else {
        return CleanResult(text: raw, usedFallback: true, reason: Self.describe(status: status))
      }
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let content = json["content"] as? [[String: Any]]
      else { return CleanResult(text: raw, usedFallback: true, reason: "Respuesta inesperada") }
      if (json["stop_reason"] as? String) == "refusal" {
        return CleanResult(text: raw, usedFallback: true, reason: "El modelo no procesó el texto")
      }
      let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty && raw.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
        return CleanResult(text: raw, usedFallback: true, reason: "Limpieza vacía")
      }
      return CleanResult(text: text, usedFallback: false)
    } catch {
      let reason = (error as? URLError)?.code == .timedOut ? "La limpieza tardó demasiado" : "Sin conexión"
      return CleanResult(text: raw, usedFallback: true, reason: reason)
    }
  }

  /// Abre la conexión con la API al empezar a dictar (petición gratuita), para no pagar el saludo TLS al final.
  public func warmUp() {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
    req.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.timeoutInterval = 3
    session.dataTask(with: req).resume()
  }

  static func describe(status: Int) -> String {
    switch status {
    case 401, 403: return "La clave de API no es válida"
    case 429: return "Límite de uso de la API"
    case 500...599: return "La API no está disponible"
    default: return "Error de la API (\(status))"
    }
  }
}

public enum CleanupHeuristics {
  static let fillers = ["eh", "este", "o sea", "pues", "bueno", "mmm", "em", "ehh", "no perdón", "perdón", "digo"]

  /// Dictados muy cortos y sin muletillas se pegan tal cual: ahorra la latencia de la API.
  public static func needsCleanup(_ raw: String) -> Bool {
    let words = TextNormalizer.normalize(raw)
    if words.count > 6 { return true }
    let joined = " " + words.joined(separator: " ") + " "
    return fillers.contains { joined.contains(" \($0) ") }
  }
}
