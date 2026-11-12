import Foundation

public struct DictationTimings: Sendable, Equatable, Codable {
  public var transcription: Double = 0
  public var cleanup: Double = 0
  public var total: Double = 0
  public init() {}
}

public struct DictationResult: Sendable, Equatable {
  public var raw: String
  public var final: String
  public var usedFallback: Bool
  public var fallbackReason: String?
  public var skipped: Bool
  public var timings: DictationTimings
}

public final class DictationPipeline: Sendable {
  public let transcriber: any Transcriber
  public let cleaner: any Cleaner
  public let dictionary: PersonalDictionary
  /// Voz mínima para procesar un dictado, en segundos.
  public static let minimumSpeech = 0.3

  public init(transcriber: any Transcriber, cleaner: any Cleaner, dictionary: PersonalDictionary) {
    self.transcriber = transcriber
    self.cleaner = cleaner
    self.dictionary = dictionary
  }

  public func run(samples: [Float], sampleRate: Int, tone: Tone, localOnly: Bool) async throws -> DictationResult {
    let clock = ContinuousClock()
    let start = clock.now
    var timings = DictationTimings()
    let speech = Self.trimSilence(samples, sampleRate: sampleRate)
    if Double(speech.count) / Double(sampleRate) < Self.minimumSpeech {
      return DictationResult(raw: "", final: "", usedFallback: false, skipped: true, timings: timings)
    }
    let raw = try await transcriber.transcribe(speech, sampleRate: sampleRate, prompt: dictionary.whisperPrompt)
    timings.transcription = Self.seconds(clock.now - start)
    return await cleanup(raw: raw, tone: tone, context: nil, localOnly: localOnly, timings: timings, start: start)
  }

  /// Segunda mitad del pipeline: limpia un texto ya transcrito (por ejemplo, por `StreamingDictation`).
  public func cleanup(raw: String, tone: Tone, context: ScreenContext?, localOnly: Bool,
                      timings: DictationTimings = DictationTimings(), start: ContinuousClock.Instant? = nil) async -> DictationResult {
    let clock = ContinuousClock()
    let start = start ?? clock.now
    var timings = timings
    if raw.isEmpty || Self.isWhisperNoise(raw) {
      timings.total = Self.seconds(clock.now - start)
      return DictationResult(raw: raw, final: "", usedFallback: false, skipped: true, timings: timings)
    }
    var final = raw
    var usedFallback = false
    var reason: String?
    if !localOnly && CleanupHeuristics.needsCleanup(raw) {
      let t = clock.now
      var result = await cleaner.clean(raw, tone: tone, dictionary: dictionary, context: context)
      // La limpieza a veces borra una parte que no entiende y con ella un "no", lo que invierte el sentido: se repite
      // una vez y, si lo vuelve a hacer, se pega lo que transcribió Whisper.
      if !result.usedFallback && NegationGuard.lostNegation(raw: raw, cleaned: result.text) {
        result = await cleaner.clean(raw, tone: tone, dictionary: dictionary, context: context)
        if !result.usedFallback && NegationGuard.lostNegation(raw: raw, cleaned: result.text) {
          result = CleanResult(text: raw, usedFallback: false)
        }
      }
      timings.cleanup = Self.seconds(clock.now - t)
      final = result.text
      usedFallback = result.usedFallback
      reason = result.reason
    }
    timings.total = Self.seconds(clock.now - start)
    return DictationResult(raw: raw, final: final, usedFallback: usedFallback, fallbackReason: reason, skipped: final.isEmpty, timings: timings)
  }

  public static func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
  }

  /// Whisper inventa estas frases con audio vacío o ruido.
  static func isWhisperNoise(_ text: String) -> Bool {
    let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    let known = ["[blank_audio]", "subtítulos realizados por la comunidad de amara.org", "gracias por ver el video", "¡gracias por ver el video", "música", "[música]", "(música)"]
    return t.isEmpty || known.contains { t.contains($0.trimmingCharacters(in: .punctuationCharacters)) }
  }

  /// Recorta el silencio de los extremos por energía en ventanas de 20 ms, con 150 ms de margen.
  public static func trimSilence(_ samples: [Float], sampleRate: Int) -> [Float] {
    let win = max(1, sampleRate / 50)
    let count = samples.count / win
    guard count > 0 else { return [] }
    var energies = [Float](repeating: 0, count: count)
    var peak: Float = 0
    for w in 0..<count {
      var sum: Float = 0
      for i in (w * win)..<((w + 1) * win) { sum += samples[i] * samples[i] }
      energies[w] = (sum / Float(win)).squareRoot()
      peak = max(peak, energies[w])
    }
    let threshold = max(0.006, peak * 0.08)
    guard let first = energies.firstIndex(where: { $0 > threshold }),
      let last = energies.lastIndex(where: { $0 > threshold })
    else { return [] }
    let voiced = energies[first...last].filter { $0 > threshold }.count
    if Double(voiced * win) / Double(sampleRate) < minimumSpeech { return [] }
    let pad = sampleRate * 15 / 100
    let from = max(0, first * win - pad)
    let to = min(samples.count, (last + 1) * win + pad)
    return Array(samples[from..<to])
  }
}

/// Revisa que la limpieza no haya quitado negaciones que Whisper sí escribió.
public enum NegationGuard {
  static let words: Set<String> = ["no", "nunca", "jamás", "tampoco"]

  public static func lostNegation(raw: String, cleaned: String) -> Bool {
    count(raw, skipCorrections: true) > count(cleaned, skipCorrections: false)
  }

  /// Negaciones del texto, sin contar las repetidas seguidas ("no, no, no sé" vale una). En la transcripción tampoco
  /// cuentan las que van seguidas de coma: son autocorrecciones ("el martes, no, el miércoles") que sí se quitan.
  static func count(_ text: String, skipCorrections: Bool) -> Int {
    let tokens = text.lowercased().split(whereSeparator: { $0.isWhitespace })
    var n = 0
    var previous = ""
    for t in tokens {
      let word = t.trimmingCharacters(in: .punctuationCharacters)
      defer { previous = word }
      guard words.contains(word), word != previous else { continue }
      if skipCorrections && t.hasSuffix(",") { continue }
      n += 1
    }
    return n
  }
}
