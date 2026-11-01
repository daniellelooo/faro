import Foundation

/// Transcribe una reunión larga mientras ocurre: corta en pausas tras ~15 s de voz (tramos de 28 s como máximo) y
/// transcribe cada tramo en segundo plano, en orden. Cada vez que termina un tramo avisa con la lista completa, para
/// guardarla en disco: si la app se cierra, no se pierde lo transcrito.
public final class MeetingTranscriber: @unchecked Sendable {
  public static let minSegment = 15.0
  public static let maxSegment = 28.0

  private let transcriber: any Transcriber
  private let sampleRate: Int
  private let dictionary: PersonalDictionary
  private let onUpdate: @Sendable ([TranscriptSegment]) -> Void
  /// Con el copiloto se corta más corto (2-12 s) para que una pregunta llegue apenas termina.
  private let minSegment: Double
  private let maxSegment: Double
  private let lock = NSLock()
  private var buffer: [Float] = []
  /// Muestras ya enviadas y descartadas del búfer (para calcular tiempos absolutos).
  private var offset = 0
  private var lastCheck = 0
  private var chain: Task<[TranscriptSegment], Error> = Task { [] }

  public init(transcriber: any Transcriber, sampleRate: Int, dictionary: PersonalDictionary,
              minSegment: Double = MeetingTranscriber.minSegment, maxSegment: Double = MeetingTranscriber.maxSegment,
              onUpdate: @escaping @Sendable ([TranscriptSegment]) -> Void) {
    self.minSegment = minSegment
    self.maxSegment = maxSegment
    self.transcriber = transcriber
    self.sampleRate = sampleRate
    self.dictionary = dictionary
    self.onUpdate = onUpdate
  }

  public var elapsed: Double { lock.withLock { Double(offset + buffer.count) / Double(sampleRate) } }

  public func append(_ samples: [Float]) {
    lock.withLock {
      buffer.append(contentsOf: samples)
      guard buffer.count - lastCheck >= sampleRate else { return }
      lastCheck = buffer.count
      if let cut = SpeechSegmenter.nextCut(in: buffer, from: 0, sampleRate: sampleRate,
                                           minSegment: minSegment, maxSegment: maxSegment,
                                           silenceFloor: 0.0008) {
        let segment = Array(buffer[0..<cut])
        enqueue(segment, startSample: offset)
        // Se libera la memoria de lo ya enviado: una reunión de horas no se queda entera en RAM.
        buffer.removeFirst(cut)
        offset += cut
        lastCheck = 0
      }
    }
  }

  public func finish() async throws -> [TranscriptSegment] {
    lock.withLock {
      enqueue(buffer, startSample: offset)
      offset += buffer.count
      buffer.removeAll()
    }
    return try await chain.value
  }

  private func enqueue(_ samples: [Float], startSample: Int) {
    let previous = chain
    let transcriber = self.transcriber
    let rate = Double(sampleRate)
    let sampleRate = self.sampleRate
    let base = dictionary.whisperPrompt
    let onUpdate = self.onUpdate
    chain = Task {
      var segments = try await previous.value
      // Voz lejana: se limpia y se sube el volumen antes de recortar silencios (si no, la voz baja se toma por silencio).
      let conditioned = AudioConditioner.forDistantSpeech(samples, sampleRate: sampleRate)
      let voiced = DictationPipeline.trimSilence(conditioned, sampleRate: sampleRate)
      guard !voiced.isEmpty else { return segments }
      // Sin el texto de los tramos anteriores en el prompt: una frase inventada se volvía a pedir y entraba en bucle.
      let raw = try await transcriber.transcribeRobust(voiced, sampleRate: sampleRate, prompt: base)
      guard let text = RepetitionFilter.clean(raw) else { return segments }
      let start = Double(startSample) / rate
      segments.append(TranscriptSegment(start: start, end: start + Double(samples.count) / rate, text: text))
      onUpdate(segments)
      return segments
    }
  }
}
