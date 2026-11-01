import Foundation

/// Lo que hay en pantalla donde se va a pegar, leído por Accesibilidad al empezar a dictar.
public struct ScreenContext: Sendable, Equatable, Codable {
  public var appName: String
  public var windowTitle: String?
  public var textBefore: String?
  public var textAfter: String?
  public var selectedText: String?

  public init(appName: String, windowTitle: String?, textBefore: String?, textAfter: String?, selectedText: String?) {
    self.appName = appName
    self.windowTitle = windowTitle
    self.textBefore = textBefore
    self.textAfter = textAfter
    self.selectedText = selectedText
  }

  public static let limit = 500

  /// Solo lo cercano al cursor: 500 caracteres antes y después.
  public var trimmed: ScreenContext {
    ScreenContext(
      appName: appName,
      windowTitle: windowTitle.map { String($0.prefix(200)) },
      textBefore: textBefore.map { String($0.suffix(Self.limit)) },
      textAfter: textAfter.map { String($0.prefix(Self.limit)) },
      selectedText: selectedText.map { String($0.prefix(Self.limit)) })
  }

  public var isEmpty: Bool {
    [windowTitle, textBefore, textAfter, selectedText].allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
}
