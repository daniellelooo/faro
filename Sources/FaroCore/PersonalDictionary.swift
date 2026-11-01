import Foundation

/// Palabras que deben escribirse exactamente así: nombres propios, marcas y términos técnicos.
public struct PersonalDictionary: Sendable, Codable, Equatable {
  public var words: [String]

  public init(words: [String]) {
    self.words = words
  }

  public static let `default` = PersonalDictionary(words: [
    "Claude", "Claude Code", "GitHub", "React", "TypeScript", "Next.js", "Supabase", "Vercel", "WhatsApp",
  ])

  /// Contexto inicial para Whisper: sesga la transcripción hacia estas palabras.
  public var whisperPrompt: String {
    "Vocabulario: " + words.joined(separator: ", ") + "."
  }
}
