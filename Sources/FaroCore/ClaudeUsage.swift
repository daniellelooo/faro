import Foundation

public struct TokenUsage: Equatable, Sendable, Codable {
  public var input = 0
  public var output = 0
  public var cacheRead = 0
  public var cacheWrite5m = 0
  public var cacheWrite1h = 0
  public var cost = 0.0

  public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite5m = cacheWrite5m
    self.cacheWrite1h = cacheWrite1h
  }

  public var totalTokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

  public static func += (l: inout TokenUsage, r: TokenUsage) {
    l.input += r.input
    l.output += r.output
    l.cacheRead += r.cacheRead
    l.cacheWrite5m += r.cacheWrite5m
    l.cacheWrite1h += r.cacheWrite1h
    l.cost += r.cost
  }
}

/// Precios de lista de la API de Anthropic (dólares por millón de tokens), tomados de la referencia de la API
/// (2026-10-06). La caché leída cuesta 0,1× la entrada; escribir caché de 5 min, 1,25×; de 1 hora, 2×.
/// El modo rápido cuesta el doble.
public enum ModelPricing {
  public struct Price: Equatable, Sendable { public var input: Double; public var output: Double }

  static let table: [String: Price] = [
    "claude-fable-5-1": Price(input: 10, output: 50), "claude-fable-5": Price(input: 10, output: 50),
    "claude-mythos-5-1": Price(input: 10, output: 50), "claude-mythos-5": Price(input: 10, output: 50),
    "claude-opus-5-5": Price(input: 4, output: 20), "claude-opus-5": Price(input: 5, output: 25),
    "claude-opus-4-8": Price(input: 5, output: 25), "claude-opus-4-7": Price(input: 5, output: 25),
    "claude-opus-4-6": Price(input: 5, output: 25),
    "claude-sonnet-5-5": Price(input: 2, output: 10), "claude-sonnet-5": Price(input: 2, output: 10),
    "claude-sonnet-4-6": Price(input: 3, output: 15),
    "claude-haiku-5-5": Price(input: 0.10, output: 0.50), "claude-haiku-4-5": Price(input: 1, output: 5),
  ]

  public static func price(for model: String) -> Price? {
    let m = model.lowercased()
    if let p = table[m] { return p }
    if let exact = table.first(where: { m.hasPrefix($0.key) })?.value { return exact }
    // Modelos nuevos que todavía no están en la tabla: precio de la generación actual de su familia.
    if m.contains("fable") || m.contains("mythos") { return table["claude-fable-5-1"] }
    if m.contains("opus") { return table["claude-opus-5-5"] }
    if m.contains("sonnet") { return table["claude-sonnet-5-5"] }
    if m.contains("haiku") { return table["claude-haiku-5-5"] }
    return nil
  }

  public static func cost(model: String, usage u: TokenUsage, fast: Bool) -> Double {
    guard let p = price(for: model) else { return 0 }
    let inputSide = Double(u.input) + Double(u.cacheRead) * 0.1 + Double(u.cacheWrite5m) * 1.25 + Double(u.cacheWrite1h) * 2
    let dollars = (inputSide * p.input + Double(u.output) * p.output) / 1_000_000
    return fast ? dollars * 2 : dollars
  }
}

public struct UsageReport: Sendable {
  public var messages = 0
  public var byModel: [String: TokenUsage] = [:]
  /// Costo por día (inicio del día local).
  public var byDay: [Date: Double] = [:]
  /// Uso por carpeta de trabajo (cwd de la sesión).
  public var projects: [ProjectUsage] = []
  public var totalCost: Double { byModel.values.reduce(0) { $0 + $1.cost } }
  public var totalTokens: Int { byModel.values.reduce(0) { $0 + $1.totalTokens } }

  public func cost(since: Date) -> Double {
    byDay.filter { $0.key >= Calendar.current.startOfDay(for: since) }.values.reduce(0, +)
  }
}

/// Lo que se hizo con Claude Code en una carpeta.
public struct ProjectUsage: Sendable, Equatable {
  public var path: String
  public var costByDay: [Date: Double] = [:]
  public var sessions = 0
  public var lastActivity: Date?
  public init(path: String) { self.path = path }

  public var name: String { URL(fileURLWithPath: path).lastPathComponent }
  public func cost(since: Date) -> Double {
    costByDay.filter { $0.key >= Calendar.current.startOfDay(for: since) }.values.reduce(0, +)
  }
}

/// Lee los registros de sesión de Claude Code (`~/.claude/projects/**/*.jsonl`) y estima el valor a precio de API.
/// El formato es interno de Claude Code: se toleran líneas rotas y campos faltantes.
public struct ClaudeUsageReader: Sendable {
  public let root: URL
  public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
    self.root = root
  }

  public func read(since: Date) -> UsageReport {
    var report = UsageReport()
    var seen = Set<String>()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter()
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return report }
    for case let url as URL in files where url.pathExtension == "jsonl" {
      if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod < since { continue }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in text.split(separator: "\n") where line.contains("\"usage\"") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let message = obj["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any],
          let model = message["model"] as? String
        else { continue }
        // Cada bloque de una respuesta repite el mismo uso: se cuenta una vez por mensaje.
        let key = (message["id"] as? String) ?? (obj["requestId"] as? String) ?? (obj["uuid"] as? String) ?? ""
        if !key.isEmpty {
          if seen.contains(key) { continue }
          seen.insert(key)
        }
        let stamp = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } ?? Date()
        if stamp < since { continue }
        let int = { (k: String) in (usage[k] as? NSNumber)?.intValue ?? 0 }
        var u = TokenUsage(input: int("input_tokens"), output: int("output_tokens"), cacheRead: int("cache_read_input_tokens"))
        if let detail = usage["cache_creation"] as? [String: Any] {
          u.cacheWrite5m = (detail["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
          u.cacheWrite1h = (detail["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        } else {
          u.cacheWrite5m = int("cache_creation_input_tokens")
        }
        u.cost = ModelPricing.cost(model: model, usage: u, fast: (usage["speed"] as? String) == "fast")
        report.messages += 1
        report.byModel[model, default: TokenUsage()] += u
        report.byDay[Calendar.current.startOfDay(for: stamp), default: 0] += u.cost
      }
    }
    return report
  }
}

/// Lectura rápida de una línea del registro: solo modelo, id, fecha y el objeto `usage`, sin interpretar el contenido
/// del mensaje (que puede ocupar megas).
public enum UsageLineParser {
  public struct Parsed { public var id: String?; public var model: String; public var date: Date?; public var usage: TokenUsage; public var fast: Bool }

  static func value(after key: String, in s: Substring) -> Substring? {
    guard let r = s.range(of: key) else { return nil }
    let rest = s[r.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return rest[..<end]
  }

  /// Primera carpeta de trabajo (`"cwd"`) que aparezca en el texto.
  public static func cwd(in text: Substring) -> String? {
    guard let v = value(after: "\"cwd\":\"", in: text) else { return nil }
    return String(v).replacingOccurrences(of: "\\/", with: "/")
  }

  public static func parse(_ line: Substring) -> Parsed? {
    guard let msg = line.range(of: "\"message\":{") else { return nil }
    let message = line[msg.upperBound...]
    guard let model = value(after: "\"model\":\"", in: message), let u = line.range(of: "\"usage\":{") else { return nil }
    // El objeto usage no tiene cadenas con llaves: basta contar llaves.
    var depth = 0
    var end = u.upperBound
    var i = line.index(before: u.upperBound)
    while i < line.endIndex {
      let c = line[i]
      if c == "{" { depth += 1 } else if c == "}" {
        depth -= 1
        if depth == 0 { end = line.index(after: i); break }
      }
      i = line.index(after: i)
    }
    let usageText = line[line.index(before: u.upperBound)..<end]
    guard let usage = try? JSONSerialization.jsonObject(with: Data(usageText.utf8)) as? [String: Any] else { return nil }
    let int = { (k: String) in (usage[k] as? NSNumber)?.intValue ?? 0 }
    var t = TokenUsage(input: int("input_tokens"), output: int("output_tokens"), cacheRead: int("cache_read_input_tokens"))
    if let d = usage["cache_creation"] as? [String: Any] {
      t.cacheWrite5m = (d["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue ?? 0
      t.cacheWrite1h = (d["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
    } else {
      t.cacheWrite5m = int("cache_creation_input_tokens")
    }
    let id = value(after: "\"id\":\"", in: message).map(String.init)
    var date: Date?
    if let tr = line.range(of: "\"timestamp\":\"", options: .backwards) {
      let rest = line[tr.upperBound...]
      if let e = rest.firstIndex(of: "\"") { date = parseDate(String(rest[..<e])) }
    }
    return Parsed(id: id, model: String(model), date: date, usage: t, fast: (usage["speed"] as? String) == "fast")
  }

  nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  nonisolated(unsafe) static let iso = ISO8601DateFormatter()
  static func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }
}

/// Uso acumulado por archivo, guardado en disco. Los registros solo crecen: se lee desde donde se quedó la vez anterior.
public final class UsageCache: @unchecked Sendable {
  struct FileState: Codable {
    var offset: UInt64
    var lastID: String?
    /// "yyyy-MM-dd|modelo" → uso
    var buckets: [String: TokenUsage]
    /// Carpeta donde corrió la sesión y última escritura del archivo.
    var cwd: String?
    var modified: Date?
  }
  let root: URL
  let cacheFile: URL
  private var files: [String: FileState] = [:]
  private let lock = NSLock()

  public static var defaultCacheFile: URL {
    ClaudeIntegration.dataDirectory.appendingPathComponent("uso-cache.json")
  }

  public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
              cacheFile: URL = UsageCache.defaultCacheFile) {
    self.root = root
    self.cacheFile = cacheFile
    if let data = try? Data(contentsOf: cacheFile), let f = try? JSONDecoder().decode([String: FileState].self, from: data) {
      files = f
    }
  }

  static let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Lee lo nuevo de cada archivo y devuelve el informe completo (todo el historial disponible).
  public func refresh() -> UsageReport {
    lock.lock()
    defer { lock.unlock() }
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
    var present = Set<String>()
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "jsonl" else { continue }
      let path = url.path
      present.insert(path)
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      let size = UInt64(values?.fileSize ?? 0)
      var state = files[path] ?? FileState(offset: 0, lastID: nil, buckets: [:])
      if size < state.offset { state = FileState(offset: 0, lastID: nil, buckets: [:]) }
      state.modified = values?.contentModificationDate
      // Cachés de versiones anteriores no guardaban la carpeta: se busca al principio del archivo.
      if state.cwd == nil, state.offset > 0, let h = try? FileHandle(forReadingFrom: url) {
        let head = String(decoding: h.readData(ofLength: 256 * 1024), as: UTF8.self)
        try? h.close()
        state.cwd = UsageLineParser.cwd(in: Substring(head))
      }
      files[path] = state
      guard size > state.offset, let h = try? FileHandle(forReadingFrom: url) else { continue }
      try? h.seek(toOffset: state.offset)
      let data = h.readDataToEndOfFile()
      try? h.close()
      // Solo hasta el último salto de línea: una línea a medio escribir se lee la próxima vez.
      guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
      let chunk = data[data.startIndex...lastNewline]
      state.offset += UInt64(chunk.count)
      let text = String(decoding: chunk, as: UTF8.self)
      if state.cwd == nil { state.cwd = UsageLineParser.cwd(in: Substring(text)) }
      var seen = Set<String>()
      if let l = state.lastID { seen.insert(l) }
      for line in text.split(separator: "\n") where line.contains("\"usage\":{") {
        guard let p = UsageLineParser.parse(line) else { continue }
        if let id = p.id {
          if seen.contains(id) { continue }
          seen.insert(id)
          state.lastID = id
        }
        var u = p.usage
        u.cost = ModelPricing.cost(model: p.model, usage: u, fast: p.fast)
        let key = Self.dayFormat.string(from: p.date ?? Date()) + "|" + p.model
        state.buckets[key, default: TokenUsage()] += u
      }
      files[path] = state
    }
    for k in files.keys where !present.contains(k) { files[k] = nil }
    if let data = try? JSONEncoder().encode(files) {
      try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: cacheFile, options: .atomic)
    }
    var report = UsageReport()
    var projects: [String: ProjectUsage] = [:]
    for (path, state) in files {
      var project = state.cwd.map { projects[$0] ?? ProjectUsage(path: $0) }
      for (key, u) in state.buckets {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let day = Self.dayFormat.date(from: String(parts[0])) else { continue }
        report.byModel[String(parts[1]), default: TokenUsage()] += u
        report.byDay[day, default: 0] += u.cost
        report.messages += 1
        project?.costByDay[day, default: 0] += u.cost
      }
      if var p = project {
        // Los subagentes viven dentro de la sesión que los lanzó: no cuentan como sesión aparte.
        if !path.contains("/subagents/") { p.sessions += 1 }
        if let m = state.modified, m > (p.lastActivity ?? .distantPast) { p.lastActivity = m }
        projects[p.path] = p
      }
    }
    report.projects = projects.values.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    return report
  }
}
