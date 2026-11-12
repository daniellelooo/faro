// Banco de pruebas de Faro: sintetiza cada caso con las voces del Mac, corre el pipeline completo
// (Whisper local + limpieza con Claude) y escribe bench-out/informe.md y bench-out/resultados.json.
import FaroCore
import Foundation

struct Case: Codable {
  var id: String
  var kind: String
  var spoken: String
  var ideal: String
  var tone: String?
  var dictionary: [String]?
  var mustNotContain: [String]?
  var listItems: Int?
}

struct Row: Codable {
  var id: String
  var kind: String
  var voice: String
  var raw: String
  var clean: String
  var werRaw: Double
  var werClean: Double
  var pass: Bool
  var note: String
  var fallback: Bool
  var tTranscription: Double
  var tCleanup: Double
  var tTotal: Double
}

let voices = ["Eddy (Español (México))", "Flo (Español (México))", "Eddy (Español (España))", "Flo (Español (España))"]
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("bench-out")
let audioDir = out.appendingPathComponent("audio")
try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

/// Corre un proceso con tiempo máximo; `say` a veces se cuelga, así que se reintenta.
func run(_ exe: String, _ args: [String], timeout: TimeInterval = 20, attempts: Int = 3) throws {
  for attempt in 1...attempts {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    try p.run()
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning {
      p.terminate()
      FileHandle.standardError.write(Data("\(exe) se colgó (intento \(attempt))\n".utf8))
      continue
    }
    if p.terminationStatus == 0 { return }
  }
  throw NSError(domain: exe, code: -1)
}

func samples(for c: Case, voice: String) throws -> [Float] {
  let f32 = audioDir.appendingPathComponent("\(c.id).f32")
  if !FileManager.default.fileExists(atPath: f32.path) {
    let aiff = audioDir.appendingPathComponent("\(c.id).aiff").path
    try run("/usr/bin/say", ["-v", voice, "-o", aiff, c.spoken])
    try run("/opt/homebrew/bin/ffmpeg", ["-loglevel", "error", "-y", "-i", aiff, "-ar", "16000", "-ac", "1", "-f", "f32le", f32.path])
    try? FileManager.default.removeItem(atPath: aiff)
  }
  let data = try Data(contentsOf: f32)
  // Medio segundo de silencio a cada lado, como al soltar la tecla.
  let pad = [Float](repeating: 0, count: 8000)
  let audio = pad + data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } + pad
  return farNoise.map { farAway(audio, noise: $0) } ?? audio
}

/// Modo lejos (BENCH_LEJOS=ruido.f32): la voz 20 dB más baja, como hablando a un par de metros del Mac, con el ruido
/// de una pieza real (grabado a 16 kHz) sonando debajo todo el tiempo.
let farNoise: [Float]? = ProcessInfo.processInfo.environment["BENCH_LEJOS"].flatMap { path in
  (try? Data(contentsOf: URL(fileURLWithPath: path))).map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
}

func farAway(_ voice: [Float], noise: [Float]) -> [Float] {
  let gain: Float = 0.1
  return voice.enumerated().map { i, v in v * gain + noise[i % noise.count] }
}

/// Como en la app: el audio llega por trozos a StreamingDictation y al soltar se transcribe lo que falta.
func streamTranscribe(_ samples: [Float], transcriber: any Transcriber, dictionary: PersonalDictionary) async throws -> String {
  let stream = StreamingDictation(transcriber: transcriber, sampleRate: 16000, dictionary: dictionary)
  var i = 0
  while i < samples.count {
    stream.append(Array(samples[i..<min(samples.count, i + 341)]))
    i += 341
  }
  return try await stream.finish()
}

func percentile(_ v: [Double], _ p: Double) -> Double {
  let s = v.sorted()
  guard !s.isEmpty else { return 0 }
  return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}

func containsWord(_ text: String, _ word: String) -> Bool {
  let t = " " + TextNormalizer.normalize(text).joined(separator: " ") + " "
  let w = TextNormalizer.normalize(word).joined(separator: " ")
  return t.contains(" \(w) ")
}

// `dicta-bench --audio archivo.f32`: transcribe una grabación real (16 kHz mono) por el camino de la app y la imprime.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--audio" {
  let server = WhisperServer()
  try await server.start()
  let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
  let audio = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  let t = WhisperServerTranscriber(server: server)
  // El diccionario guardado en la app instalada (su identificador sale de su Info.plist), o el de por defecto.
  let appID = Bundle(url: URL(fileURLWithPath: "/Applications/Faro.app"))?.bundleIdentifier
  let words = appID.flatMap { UserDefaults(suiteName: $0)?.stringArray(forKey: "diccionarioPalabras") } ?? PersonalDictionary.default.words
  let dict = PersonalDictionary(words: words)
  let voiced = DictationPipeline.trimSilence(audio, sampleRate: 16000)
  let natural = "Hablo de " + words.joined(separator: ", ") + "."
  print("A por tramos, prompt actual:\n ", try await streamTranscribe(audio, transcriber: t, dictionary: dict))
  var c0 = ContinuousClock.now
  _ = try await streamTranscribe(audio, transcriber: t, dictionary: dict)
  print("tiempo total por tramos (sin simular el tiempo real):", ContinuousClock.now - c0)
  c0 = ContinuousClock.now
  print("B entero, prompt actual:\n ", try await t.transcribe(voiced, sampleRate: 16000, prompt: dict.whisperPrompt))
  print("tiempo B:", ContinuousClock.now - c0, "audio", Double(voiced.count) / 16000, "s")
  c0 = ContinuousClock.now
  _ = try await t.transcribeRobust(voiced, sampleRate: 16000, prompt: dict.whisperPrompt)
  print("tiempo D (búsqueda):", ContinuousClock.now - c0)
  print("C entero, sin prompt:\n ", try await t.transcribe(voiced, sampleRate: 16000, prompt: ""))
  print("D entero, búsqueda, prompt actual:\n ", try await t.transcribeRobust(voiced, sampleRate: 16000, prompt: dict.whisperPrompt))
  print("E entero, prompt natural:\n ", try await t.transcribe(voiced, sampleRate: 16000, prompt: natural))
  await server.stop()
  exit(0)
}

// `dicta-bench --limpiar "texto"`: pasa una transcripción por la limpieza (tono literal) 5 veces y la imprime.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--limpiar" {
  let cleaner = AnthropicCleaner(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
  for _ in 0..<5 { print(await cleaner.clean(CommandLine.arguments[2], tone: .literal, dictionary: .default, context: nil).text, "\n") }
  exit(0)
}

let only = CommandLine.arguments.dropFirst().first
var cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: root.appendingPathComponent("bench/cases.json")))
if let only { cases = cases.filter { $0.id.hasPrefix(only) || $0.kind == only } }

let server = WhisperServer()
try await server.start()
// La clave llega por variable de entorno: leer el Llavero desde este binario pediría la contraseña del Mac.
let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
if apiKey == nil { print("Falta ANTHROPIC_API_KEY. Usa: scripts/bench.sh") }
// El diccionario por defecto más los nombres propios (inventados) que usan los casos, sin repetir.
let benchDictionary = PersonalDictionary(words: (PersonalDictionary.default.words + cases.flatMap { $0.dictionary ?? [] })
  .reduce(into: [String]()) { words, w in if !words.contains(w) { words.append(w) } })
let pipeline = DictationPipeline(
  transcriber: WhisperServerTranscriber(server: server),
  cleaner: AnthropicCleaner(apiKey: apiKey),
  dictionary: benchDictionary)

// Calentamiento: la primera inferencia y la primera conexión TLS son más lentas.
_ = try await pipeline.run(samples: try samples(for: cases[0], voice: voices[0]), sampleRate: 16000, tone: .neutral, localOnly: false)

var rows: [Row] = []
var dictTotal = 0
var dictHits = 0
for (i, c) in cases.enumerated() {
  // Pausa entre dictados (no cuenta en la latencia): evita el límite de peticiones por minuto de la API.
  try await Task.sleep(for: .seconds(1.2))
  let voice = voices[i % voices.count]
  let tone = c.tone.flatMap(Tone.init(rawValue:)) ?? .neutral
  let audio = try samples(for: c, voice: voice)
  let r: DictationResult
  if farNoise != nil || ProcessInfo.processInfo.environment["BENCH_STREAM"] != nil {
    let t0 = ContinuousClock.now
    let raw = try await streamTranscribe(audio, transcriber: pipeline.transcriber, dictionary: pipeline.dictionary)
    var timings = DictationTimings()
    timings.transcription = DictationPipeline.seconds(ContinuousClock.now - t0)
    r = await pipeline.cleanup(raw: raw, tone: tone, context: nil, localOnly: false, timings: timings, start: t0)
  } else {
    r = try await pipeline.run(samples: audio, sampleRate: 16000, tone: tone, localOnly: false)
  }
  let werRaw = WER.compute(reference: c.ideal, hypothesis: r.raw)
  let werClean = WER.compute(reference: c.ideal, hypothesis: r.final)
  var pass = true
  var notes: [String] = []
  for w in c.dictionary ?? [] {
    dictTotal += 1
    if r.final.contains(w) { dictHits += 1 } else { pass = false; notes.append("falta «\(w)»") }
  }
  for w in c.mustNotContain ?? [] where containsWord(r.final, w) {
    pass = false
    notes.append("quedó «\(w)»")
  }
  if let n = c.listItems {
    let items = r.final.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count
    if items < n { pass = false; notes.append("lista con \(items) de \(n)") }
  }
  if c.kind == "instruccion" && (Double(r.final.count) > Double(c.ideal.count) * 1.5 || werClean > 0.3) {
    pass = false
    notes.append("respondió en vez de transcribir")
  }
  if werClean > 0.25 { pass = false; notes.append("WER alto") }
  rows.append(Row(id: c.id, kind: c.kind, voice: voice, raw: r.raw, clean: r.final, werRaw: werRaw, werClean: werClean,
    pass: pass, note: notes.joined(separator: "; "), fallback: r.usedFallback,
    tTranscription: r.timings.transcription, tCleanup: r.timings.cleanup, tTotal: r.timings.total))
  setvbuf(stdout, nil, _IOLBF, 0)
  print(String(format: "%@ %@ WER %.2f→%.2f  %.2fs  %@", pass ? "ok   " : "FALLA", c.id, werRaw, werClean, r.timings.total, notes.joined(separator: "; ")))
}
await server.stop()

// Informe
func avg(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
let tot = rows.map(\.tTotal), tr = rows.map(\.tTranscription), cl = rows.filter { $0.tCleanup > 0 }.map(\.tCleanup)
var md = "# Banco de pruebas de Faro\n\n"
md += "Casos: \(rows.count). Voces sintéticas de macOS (es_MX y es_ES). Modelo: large-v3-turbo q5_0 + \(AnthropicCleaner.model).\n\n"
md += "| Métrica | Valor | Meta |\n|---|---|---|\n"
md += String(format: "| WER crudo (Whisper) | %.1f %% | |\n", avg(rows.map(\.werRaw)) * 100)
md += String(format: "| WER limpio | %.1f %% | ≤ 8 %% |\n", avg(rows.map(\.werClean)) * 100)
md += String(format: "| Diccionario bien escrito | %d de %d (%.0f %%) | ≥ 95 %% |\n", dictHits, dictTotal, dictTotal == 0 ? 100 : Double(dictHits) / Double(dictTotal) * 100)
for kind in ["autocorreccion", "lista", "instruccion"] {
  let k = rows.filter { $0.kind == kind }
  md += "| \(kind) que pasan | \(k.filter(\.pass).count) de \(k.count) | todos |\n"
}
md += "| Casos que pasan (todos) | \(rows.filter(\.pass).count) de \(rows.count) | |\n"
md += "| Respaldo al texto crudo | \(rows.filter(\.fallback).count) | 0 |\n"
md += String(format: "| Latencia total p50 / p90 | %.2f s / %.2f s | p50 ≤ 1,5 s |\n", percentile(tot, 0.5), percentile(tot, 0.9))
md += String(format: "| Transcripción p50 / p90 | %.2f s / %.2f s | |\n", percentile(tr, 0.5), percentile(tr, 0.9))
md += String(format: "| Limpieza p50 / p90 | %.2f s / %.2f s | |\n\n", percentile(cl, 0.5), percentile(cl, 0.9))
md += "## Casos que fallan\n\n"
for r in rows where !r.pass {
  md += "- **\(r.id)** (\(r.note))\n  - crudo: \(r.raw)\n  - limpio: \(r.clean.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
}
try md.write(to: out.appendingPathComponent("informe.md"), atomically: true, encoding: .utf8)
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted]
try enc.encode(rows).write(to: out.appendingPathComponent("resultados.json"))
print("\n" + md.components(separatedBy: "## Casos")[0])
