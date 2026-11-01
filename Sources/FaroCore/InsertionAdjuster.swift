import Foundation

/// Ajusta el texto dictado al lugar donde se va a pegar: mayúscula o minúscula según si se está a mitad de frase,
/// espacio inicial si el texto anterior no lo tiene, y sin punto final si la frase continúa después del cursor.
public enum InsertionAdjuster {
  static let sentenceEnders: Set<Character> = [".", "!", "?", "\n", "…"]
  static let openers: Set<Character> = ["(", "¿", "¡", "\"", "'", "«", "[", "{", "/", "@", "#"]

  public static func adjust(_ text: String, before: String, after: String, properNouns: [String] = []) -> String {
    guard !text.isEmpty else { return text }
    if text.hasPrefix("- ") || text.contains("\n- ") { return text }
    var t = text
    let beforeTrimmed = before.trimmingCharacters(in: .whitespaces)
    if let last = beforeTrimmed.last {
      if sentenceEnders.contains(last) || before.hasSuffix("\n") {
        t = capitalizeFirst(t)
      } else if !startsWithProperNoun(t, properNouns) {
        t = lowercaseFirst(t)
      }
      if let raw = before.last, !raw.isWhitespace, !openers.contains(raw) {
        t = " " + t
      }
    }
    let afterTrimmed = after.trimmingCharacters(in: .whitespaces)
    if let next = afterTrimmed.first, next.isLetter || next.isNumber {
      while let l = t.last, l == "." { t.removeLast() }
      if let raw = after.first, !raw.isWhitespace { t += " " }
    }
    return t
  }

  static func capitalizeFirst(_ s: String) -> String {
    guard let i = s.firstIndex(where: { $0.isLetter }) else { return s }
    return s.replacingCharacters(in: i...i, with: String(s[i]).uppercased())
  }

  static func lowercaseFirst(_ s: String) -> String {
    guard let i = s.firstIndex(where: { $0.isLetter }) else { return s }
    let word = s[i...].prefix { $0.isLetter }
    // Siglas (PR, API) y palabras con mayúsculas internas (GitHub) se dejan igual.
    if word.count > 1 && word.dropFirst().contains(where: { $0.isUppercase }) { return s }
    return s.replacingCharacters(in: i...i, with: String(s[i]).lowercased())
  }

  static func startsWithProperNoun(_ s: String, _ nouns: [String]) -> Bool {
    let trimmed = s.drop { !$0.isLetter }
    return nouns.contains { trimmed.hasPrefix($0) }
  }
}
