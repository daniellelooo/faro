import Foundation

public enum TextNormalizer {
  /// Minúsculas, sin puntuación ni viñetas; conserva tildes y dígitos.
  public static func normalize(_ text: String) -> [String] {
    let lowered = text.lowercased()
    var cleaned = ""
    for scalar in lowered.unicodeScalars {
      if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
        cleaned.unicodeScalars.append(scalar)
      } else {
        cleaned.append(" ")
      }
    }
    return cleaned.split(separator: " ").map(String.init)
  }
}

public enum WER {
  /// Error por palabra: (sustituciones + borrados + inserciones) / palabras de la referencia.
  public static func compute(reference: String, hypothesis: String) -> Double {
    let r = TextNormalizer.normalize(reference)
    let h = TextNormalizer.normalize(hypothesis)
    if r.isEmpty { return h.isEmpty ? 0 : 1 }
    var prev = Array(0...h.count)
    var cur = [Int](repeating: 0, count: h.count + 1)
    for i in 1...r.count {
      cur[0] = i
      for j in stride(from: 1, through: h.count, by: 1) {
        let cost = r[i - 1] == h[j - 1] ? 0 : 1
        cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      }
      swap(&prev, &cur)
    }
    return Double(prev[h.count]) / Double(r.count)
  }
}
