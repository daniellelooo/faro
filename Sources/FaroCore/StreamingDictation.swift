import Foundation

/// Transcribe el dictado. Whisper acierta mucho más con la frase entera que con pedazos de pocos segundos (con la voz
/// lejana, cortar en cada pausa partía frases y salían cosas como "un TikTok como un balo" por "un dictado como malo"),
/// y entero tarda poco: unos 1,4 s para 35 s de audio. Así que solo se adelanta trabajo mientras se habla en dictados
/// largos: tras `minSegment` segundos, en la siguiente pausa, ese pedazo se transcribe en segundo plano. Al soltar la
/// tecla se transcribe lo que falta. (La búsqueda más cuidadosa de Whisper no ayudó: igual en audio real, algo peor con
/// voz lejana en el banco, y 0,4 s más lenta.)
public final class StreamingDictation: @unchecked Sendable {
  private let transcriber: any Transcriber
  private let sampleRate: Int
  private let dictionary: PersonalDictionary
  private let lock = NSLock()
  private var buffer: [Float] = []
  private var cursor = 0
  private var lastCheck = 0
  private var chain: Task<[String], Error> = Task { [] }
  /// Pedazos enviados a transcribir antes de soltar la tecla (para medir).
  public private(set) var earlySegments = 0

  /// Voz mínima antes de adelantar un pedazo, y largo máximo de un pedazo.
  let minSegment: Double
  let maxSegment: Double

  public init(transcriber: any Transcriber, sampleRate: Int, dictionary: PersonalDictionary,
              minSegment: Double = 45, maxSegment: Double = 55) {
    self.transcriber = transcriber
    self.sampleRate = sampleRate
    self.dictionary = dictionary
    self.minSegment = minSegment
    self.maxSegment = maxSegment
  }

  /// Agrega audio recién grabado. Se puede llamar desde el hilo de audio.
  public func append(_ samples: [Float]) {
    lock.withLock {
      buffer.append(contentsOf: samples)
      // Revisar cortes cada cuarto de segundo de audio nuevo, no en cada trozo de 40 ms.
      guard buffer.count - lastCheck >= sampleRate / 4 else { return }
      lastCheck = buffer.count
      if let cut = SpeechSegmenter.nextCut(in: buffer, from: cursor, sampleRate: sampleRate, minSegment: minSegment,
        maxSegment: maxSegment) {
        let segment = Array(buffer[cursor..<cut])
        cursor = cut
        earlySegments += 1
        enqueue(segment)
      }
    }
  }

  /// Todo el audio grabado.
  public var allSamples: [Float] { lock.withLock { buffer } }

  /// Transcribe lo que falta y devuelve el texto completo.
  public func finish() async throws -> String {
    lock.withLock {
      let tail = Array(buffer[cursor...])
      cursor = buffer.count
      enqueue(tail)
    }
    return try await chain.value.joined(separator: " ")
  }

  private func enqueue(_ segment: [Float]) {
    let previous = chain
    let transcriber = self.transcriber
    let sampleRate = self.sampleRate
    let basePrompt = dictionary.whisperPrompt
    chain = Task {
      var texts = try await previous.value
      let voiced = DictationPipeline.trimSilence(segment, sampleRate: sampleRate)
      guard !voiced.isEmpty else { return texts }
      let prompt = ([basePrompt] + texts.suffix(2)).joined(separator: " ")
      let text = try await transcriber.transcribe(voiced, sampleRate: sampleRate, prompt: prompt)
      if !text.isEmpty && !DictationPipeline.isWhisperNoise(text) { texts.append(text) }
      return texts
    }
  }
}
