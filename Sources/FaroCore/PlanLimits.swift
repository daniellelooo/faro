import Foundation

/// Límites del plan de Claude (5 horas, semana y por modelo), vengan de donde vengan.
public struct PlanLimits: Sendable, Equatable {
  public enum Source: String, Sendable { case account, statusLine, desktop }

  public struct Window: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// 0–100
    public var percent: Double
    public var resetsAt: Date?
    public init(id: String, title: String, percent: Double, resetsAt: Date?) {
      self.id = id
      self.title = title
      self.percent = percent
      self.resetsAt = resetsAt
    }
  }

  public var fiveHour: Window?
  public var sevenDay: Window?
  /// Límites semanales por modelo (Opus, Fable...), solo los que traen algo.
  public var models: [Window] = []
  public var source: Source
  public var fetchedAt: Date

  public init(fiveHour: Window?, sevenDay: Window?, models: [Window] = [], source: Source, fetchedAt: Date) {
    self.fiveHour = fiveHour
    self.sevenDay = sevenDay
    self.models = models
    self.source = source
    self.fetchedAt = fetchedAt
  }

  public var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

  public init?(snapshot s: StatusSnapshot, now: Date = Date()) {
    guard s.fiveHour != nil || s.sevenDay != nil else { return nil }
    fiveHour = s.fiveHour.map { Window(id: "five_hour", title: "5 horas", percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
    sevenDay = s.sevenDay.map { Window(id: "seven_day", title: "Semana", percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
    source = .statusLine
    fetchedAt = s.capturedAt ?? now
  }
}

/// Lee la respuesta del endpoint de uso de la cuenta (`/api/oauth/usage`), el mismo que consulta la app de escritorio.
public enum PlanUsageParser {
  static let modelTitles = ["seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet"]

  public static func parse(_ data: Data, now: Date = Date()) throws -> PlanLimits {
    guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
    func window(_ key: String, _ title: String) -> PlanLimits.Window? {
      guard let w = o[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
      return PlanLimits.Window(id: key, title: title, percent: u, resetsAt: (w["resets_at"] as? String).flatMap(date))
    }
    var models: [PlanLimits.Window] = []
    // Formato nuevo: lista de límites con su alcance (modelo o superficie).
    if let limits = o["limits"] as? [[String: Any]] {
      for l in limits {
        guard let scope = l["scope"] as? [String: Any], let pct = (l["percent"] as? NSNumber)?.doubleValue else { continue }
        let name = ((scope["model"] as? [String: Any])?["display_name"] as? String)
          ?? ((scope["surface"] as? [String: Any])?["display_name"] as? String)
        guard let name else { continue }
        models.append(PlanLimits.Window(id: "limit-\(name)", title: name, percent: pct, resetsAt: (l["resets_at"] as? String).flatMap(date)))
      }
    }
    for (key, title) in modelTitles.sorted(by: { $0.key < $1.key }) where !models.contains(where: { $0.title == title }) {
      if let w = window(key, title), w.percent > 0 { models.append(w) }
    }
    let result = PlanLimits(fiveHour: window("five_hour", "5 horas"), sevenDay: window("seven_day", "Semana"),
      models: models, source: .account, fetchedAt: now)
    guard !result.isEmpty else { throw CocoaError(.coderValueNotFound) }
    return result
  }

  nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  nonisolated(unsafe) static let iso = ISO8601DateFormatter()
  static func date(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
}

/// Historial que guarda la app de escritorio de Claude cuando su menú de uso está activo (una muestra cada ~15 min).
public enum DesktopUsageHistory {
  public static var defaultFile: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
  }

  /// Última muestra, solo si es reciente: un porcentaje viejo engaña más de lo que ayuda.
  public static func latest(file: URL = defaultFile, maxAge: TimeInterval = 20 * 60, now: Date = Date()) -> PlanLimits? {
    guard let data = try? Data(contentsOf: file),
      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let samples = o["samples"] as? [[String: Any]], let last = samples.last,
      let t = (last["t"] as? NSNumber)?.doubleValue, let u = last["u"] as? [String: Any]
    else { return nil }
    let when = Date(timeIntervalSince1970: t / 1000)
    guard now.timeIntervalSince(when) <= maxAge else { return nil }
    func w(_ key: String, _ id: String, _ title: String) -> PlanLimits.Window? {
      (u[key] as? NSNumber).map { PlanLimits.Window(id: id, title: title, percent: $0.doubleValue, resetsAt: nil) }
    }
    let r = PlanLimits(fiveHour: w("fh", "five_hour", "5 horas"), sevenDay: w("sd", "seven_day", "Semana"), source: .desktop, fetchedAt: when)
    return r.isEmpty ? nil : r
  }
}

/// Consulta los límites de la cuenta con un token propio de Faro (el que da `claude setup-token`).
public enum PlanUsageClient {
  public static let tokenService = "faro-claude-token"
  public enum Failure: Error, Equatable { case unauthorized, forbidden, http(Int), unreadable }

  /// Primero el endpoint de uso; si el token no tiene ese permiso (los de `claude setup-token` solo sirven para
  /// inferencia), se leen los encabezados de límite de una petición mínima, que es de donde Claude Code saca los suyos.
  public static func fetch(token: String, session: URLSession = .shared, now: Date = Date()) async throws -> PlanLimits {
    if !usageEndpointForbidden {
      do { return try await fetchUsage(token: token, session: session, now: now) } catch Failure.unauthorized {
        throw Failure.unauthorized
      } catch {
        // 403 (sin permiso) o 429 (ese endpoint limita a los tokens de inferencia): se pasa a los encabezados.
        let limits = try await probeHeaders(token: token, session: session, now: now)
        usageEndpointForbidden = true
        return limits
      }
    }
    return try await probeHeaders(token: token, session: session, now: now)
  }

  nonisolated(unsafe) public static var usageEndpointForbidden = false

  /// Lee los límites de los encabezados `anthropic-ratelimit-unified-*` (utilización de 0 a 1 y reinicio en segundos Unix).
  public static func limits(fromHeaders h: [String: String], now: Date = Date()) -> PlanLimits? {
    var lower: [String: String] = [:]
    for (k, v) in h { lower[k.lowercased()] = v }
    func w(_ key: String, _ id: String, _ title: String) -> PlanLimits.Window? {
      guard let u = lower["anthropic-ratelimit-unified-\(key)-utilization"].flatMap(Double.init) else { return nil }
      let reset = lower["anthropic-ratelimit-unified-\(key)-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
      return PlanLimits.Window(id: id, title: title, percent: u * 100, resetsAt: reset)
    }
    let r = PlanLimits(fiveHour: w("5h", "five_hour", "5 horas"), sevenDay: w("7d", "seven_day", "Semana"), source: .account, fetchedAt: now)
    return r.isEmpty ? nil : r
  }

  /// Petición de 1 token a Haiku: lo mínimo para que la API devuelva los encabezados de límite.
  static func probeHeaders(token: String, session: URLSession, now: Date) async throws -> PlanLimits {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 20)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = Data(#"{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}"#.utf8)
    let (_, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw Failure.unreadable }
    var headers: [String: String] = [:]
    for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
    // Con el límite agotado la API responde 429 pero igual trae los encabezados.
    if let l = limits(fromHeaders: headers, now: now) { return l }
    switch http.statusCode {
    case 401: throw Failure.unauthorized
    case 403: throw Failure.forbidden
    default: throw Failure.http(http.statusCode)
    }
  }

  static func fetchUsage(token: String, session: URLSession, now: Date) async throws -> PlanLimits {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("Faro", forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    switch code {
    case 200: break
    case 401: throw Failure.unauthorized
    case 403: throw Failure.forbidden
    default: throw Failure.http(code)
    }
    do { return try PlanUsageParser.parse(data, now: now) } catch { throw Failure.unreadable }
  }
}
