import Foundation

/// Cómo debe quedar el texto según la app donde se dicta.
public enum Tone: String, Sendable, Codable, CaseIterable {
  /// Fiel a lo dicho, sin reformular: terminal, editores, Claude.
  case literal
  /// Chat: Slack, WhatsApp.
  case casual
  /// Correo.
  case formal
  /// Cualquier otra app.
  case neutral
}

public enum ToneResolver {
  static let browsers: Set<String> = [
    "company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari",
  ]
  static let byBundle: [String: Tone] = [
    "com.anthropic.claudefordesktop": .literal,
    "dev.warp.Warp-Stable": .literal,
    "com.microsoft.VSCode": .literal,
    "com.apple.Terminal": .literal,
    "com.googlecode.iterm2": .literal,
    "com.todesktop.230313mzl4w4u92": .literal, // Cursor
    "net.whatsapp.WhatsApp": .casual,
    "com.apple.MobileSMS": .casual,
    "com.tinyspeck.slackmacgap": .casual,
    "com.apple.mail": .formal,
    "notion.id": .neutral,
    "com.apple.Notes": .neutral,
  ]
  static let byHost: [(suffix: String, tone: Tone)] = [
    ("mail.google.com", .formal),
    ("outlook.live.com", .formal),
    ("outlook.office.com", .formal),
    ("app.slack.com", .casual),
    ("web.whatsapp.com", .casual),
    ("claude.ai", .literal),
    ("github.com", .literal),
    ("chatgpt.com", .literal),
  ]

  public static func resolve(bundleID: String?, url: String?) -> Tone {
    guard let bundleID else { return .neutral }
    if browsers.contains(bundleID) {
      guard let url, let host = URL(string: url)?.host?.lowercased() else { return .neutral }
      for rule in byHost where host == rule.suffix || host.hasSuffix("." + rule.suffix) {
        return rule.tone
      }
      return .neutral
    }
    return byBundle[bundleID] ?? .neutral
  }

  /// Si la app activa es un navegador del que se puede leer la pestaña por AppleScript.
  public static func isBrowser(_ bundleID: String?) -> Bool {
    bundleID.map(browsers.contains) ?? false
  }
}

/// Tipo de app donde se dicta. Cada tipo tiene un estilo que la persona puede cambiar.
public enum AppCategory: String, Sendable, Codable, CaseIterable, Identifiable {
  case messaging, email, code, documents, other
  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .messaging: return "Mensajería"
    case .email: return "Correo"
    case .code: return "Código e IA"
    case .documents: return "Documentos"
    case .other: return "Otras apps"
    }
  }

  public var examples: String {
    switch self {
    case .messaging: return "WhatsApp, Slack, Mensajes"
    case .email: return "Gmail, Mail, Outlook"
    case .code: return "Claude, Warp, VS Code, terminal"
    case .documents: return "Notion, Notas"
    case .other: return "Todo lo demás"
    }
  }

  public var defaultTone: Tone {
    switch self {
    case .messaging: return .casual
    case .email: return .formal
    case .code: return .literal
    case .documents, .other: return .neutral
    }
  }

  public static func of(bundleID: String?, url: String?) -> AppCategory {
    if ToneResolver.isBrowser(bundleID) {
      guard let url, let host = URL(string: url)?.host?.lowercased() else { return .other }
      let match = { (h: String) in host == h || host.hasSuffix("." + h) }
      if ["mail.google.com", "outlook.live.com", "outlook.office.com"].contains(where: match) { return .email }
      if ["app.slack.com", "web.whatsapp.com", "discord.com"].contains(where: match) { return .messaging }
      if ["claude.ai", "github.com", "chatgpt.com"].contains(where: match) { return .code }
      if ["docs.google.com", "notion.so"].contains(where: match) { return .documents }
      return .other
    }
    switch ToneResolver.resolve(bundleID: bundleID, url: url) {
    case .casual: return .messaging
    case .formal: return .email
    case .literal: return .code
    case .neutral:
      return ["notion.id", "com.apple.Notes", "com.microsoft.Word", "com.apple.iWork.Pages"].contains(bundleID ?? "") ? .documents : .other
    }
  }
}

extension Tone {
  public var title: String {
    switch self {
    case .literal: return "Fiel a lo dicho"
    case .casual: return "Casual"
    case .formal: return "Formal"
    case .neutral: return "Neutro"
    }
  }
}

/// Estilo elegido por la persona para cada tipo de app.
public struct StylePreferences: Sendable, Codable, Equatable {
  public var tones: [AppCategory: Tone]
  public init(tones: [AppCategory: Tone] = [:]) { self.tones = tones }

  public func tone(for category: AppCategory) -> Tone { tones[category] ?? category.defaultTone }

  public func tone(bundleID: String?, url: String?) -> Tone {
    tone(for: AppCategory.of(bundleID: bundleID, url: url))
  }
}
