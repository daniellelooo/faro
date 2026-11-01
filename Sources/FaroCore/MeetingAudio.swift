import Foundation

/// Prepara audio de voz lejana (una clase o una reunión con el Mac sobre la mesa) para Whisper.
///
/// En un salón la voz llega a −45/−50 dBFS, de 10 a 20 veces más baja que dictando cerca del micrófono. Con tan poca
/// señal Whisper rellena con frases inventadas y entra en bucles. Aquí se quita el retumbo grave (aire acondicionado,
/// golpes en la mesa) y se sube el volumen poco a poco hacia un nivel de voz normal, sin subir el silencio.
public enum AudioConditioner {
  public static let targetDBFS: Float = -23
  public static let maxGainDB: Float = 30
  /// Por debajo de esto es silencio de verdad: no se amplifica.
  public static let silenceDBFS: Float = -62

  public static func forDistantSpeech(_ samples: [Float], sampleRate: Int) -> [Float] {
    guard !samples.isEmpty else { return samples }
    // Paso alto de primer orden a 90 Hz.
    let rc: Float = 1 / (2 * .pi * 90)
    let dt: Float = 1 / Float(sampleRate)
    let a = rc / (rc + dt)
    var filtered = [Float](repeating: 0, count: samples.count)
    for i in 1..<samples.count { filtered[i] = a * (filtered[i - 1] + samples[i] - samples[i - 1]) }

    // Ganancia por ventanas de 0,5 s que se acerca suave al objetivo (sin bombeo), con limitador.
    let target = pow(10, targetDBFS / 20)
    let maxGain = pow(10, maxGainDB / 20)
    let silence = pow(10, silenceDBFS / 20)
    let win = max(1, sampleRate / 2)
    let smoothing: Float = 2 / Float(sampleRate)  // ~0,5 s para llegar a la ganancia pedida
    var gain: Float = 1
    var out = [Float](repeating: 0, count: filtered.count)
    var start = 0
    while start < filtered.count {
      let end = min(filtered.count, start + win)
      var sum: Float = 0
      for i in start..<end { sum += filtered[i] * filtered[i] }
      let rms = (sum / Float(end - start)).squareRoot()
      let wanted = rms < silence ? gain : min(target / max(rms, 1e-9), maxGain)
      for i in start..<end {
        gain += (wanted - gain) * smoothing
        out[i] = max(-0.98, min(0.98, filtered[i] * gain))
      }
      start = end
    }
    return out
  }

  public static func rmsDBFS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return -120 }
    let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    return 20 * log10(max(rms, 1e-9))
  }
}

/// Limpia los bucles típicos de Whisper con audio difícil: frases o palabras repetidas una tras otra.
public enum RepetitionFilter {
  /// Devuelve el texto sin repeticiones consecutivas, o nil si lo que queda es una alucinación conocida.
  public static func clean(_ text: String) -> String? {
    // 1. Frases (por línea o por punto) repetidas seguidas: se deja una.
    var phrases: [String] = []
    var lastKey = ""
    for raw in splitPhrases(text) {
      let p = raw.trimmingCharacters(in: .whitespaces)
      guard !p.isEmpty else { continue }
      let key = normalize(p)
      if key == lastKey || key.isEmpty { continue }
      phrases.append(p)
      lastKey = key
    }
    // 2. Grupos de palabras repetidos seguidos dentro de una frase ("la pandemia, la pandemia").
    let joined = phrases.map(collapseRepeatedWords).joined(separator: " ")
    let result = joined.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if result.isEmpty || DictationPipeline.isWhisperNoise(result) || isGreetingOnly(result) { return nil }
    return result
  }

  static func splitPhrases(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    for ch in text {
      if ch == "\n" {
        out.append(current)
        current = ""
      } else {
        current.append(ch)
        if ch == "." || ch == "?" || ch == "!" {
          out.append(current)
          current = ""
        }
      }
    }
    out.append(current)
    return out
  }

  static func normalize(_ s: String) -> String {
    s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// Quita repeticiones inmediatas de 1 a 6 palabras.
  static func collapseRepeatedWords(_ phrase: String) -> String {
    var words = phrase.split(separator: " ").map(String.init)
    var changed = true
    while changed {
      changed = false
      for n in stride(from: 6, through: 1, by: -1) where words.count >= 2 * n {
        var i = 0
        while i + 2 * n <= words.count {
          let a = words[i..<(i + n)].map(normalize), b = words[(i + n)..<(i + 2 * n)].map(normalize)
          if a == b, !a.joined().isEmpty, n > 1 || a[0].count > 2 {
            words.removeSubrange((i + n)..<(i + 2 * n))
            changed = true
          } else {
            i += 1
          }
        }
      }
    }
    return words.joined(separator: " ")
  }

  /// "Gracias." suelto es la alucinación más común de Whisper sobre ruido.
  static func isGreetingOnly(_ s: String) -> Bool {
    let n = normalize(s)
    return ["gracias", "muchas gracias", "gracias gracias", "chao", "adios", "hasta luego"].contains(n)
  }
}
