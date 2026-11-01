import Foundation

/// Decide dónde cortar el audio mientras la persona sigue hablando, para transcribir por partes (en pausas naturales)
/// y que al soltar la tecla solo falte la última parte. El trabajo se hace mientras se habla, en local con Whisper.
public enum SpeechSegmenter {
  /// Voz mínima antes de cortar.
  public static let minSegment = 3.0
  /// Pausa mínima para cortar.
  public static let minPause = 0.45
  /// Ventana de Whisper: nunca dejar un segmento más largo que esto.
  public static let maxSegment = 25.0

  /// Posición (en muestras) donde cortar el próximo segmento a partir de `from`, o nil si todavía no conviene.
  public static func nextCut(in samples: [Float], from: Int, sampleRate: Int,
                             minSegment: Double = SpeechSegmenter.minSegment,
                             maxSegment: Double = SpeechSegmenter.maxSegment,
                             silenceFloor: Float = 0.008) -> Int? {
    let win = sampleRate / 50
    let start = from
    let end = samples.count
    guard end - start >= Int(minSegment * Double(sampleRate)) else { return nil }
    let count = (end - start) / win
    var energies = [Float](repeating: 0, count: count)
    var peak: Float = 0
    for w in 0..<count {
      var sum: Float = 0
      let base = start + w * win
      for i in base..<(base + win) { sum += samples[i] * samples[i] }
      energies[w] = (sum / Float(win)).squareRoot()
      peak = max(peak, energies[w])
    }
    // El piso absoluto sirve dictando cerca del micrófono; con voz lejana (reuniones) se pasa uno mucho más bajo.
    let threshold = max(silenceFloor, peak * 0.1)
    let minWin = Int(minSegment * 50)
    let pauseWins = Int(minPause * 50)
    var run = 0
    for w in 0..<count {
      if energies[w] < threshold {
        run += 1
        if run >= pauseWins && w - run + 1 >= minWin {
          let mid = w - run / 2
          return start + mid * win
        }
      } else {
        run = 0
      }
    }
    let maxLen = Int(maxSegment * Double(sampleRate))
    if end - start > maxLen { return start + maxLen }
    return nil
  }
}
