import AppKit
import ApplicationServices
import FaroCore

/// Lectura de la pantalla por Accesibilidad: el campo donde está el cursor, el texto alrededor y la ventana.
@MainActor
enum AXReader {
  struct Focus {
    var pid: pid_t
    var element: AXUIElement?
    var context: ScreenContext
    var url: String?
  }

  static func capture(app: NSRunningApplication?) -> Focus {
    let name = app?.localizedName ?? "App"
    guard let app, AXIsProcessTrusted() else {
      return Focus(pid: app?.processIdentifier ?? 0, element: nil, context: ScreenContext(appName: name, windowTitle: nil, textBefore: nil, textAfter: nil, selectedText: nil), url: browserURL(app))
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 0.25)
    // Apps Electron y Chrome solo exponen su árbol de Accesibilidad si se les pide.
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let window: AXUIElement? = copy(appElement, kAXFocusedWindowAttribute)
    let title: String? = window.flatMap { copy($0, kAXTitleAttribute) }
    let focused: AXUIElement? = copy(appElement, kAXFocusedUIElementAttribute)
    var before: String?
    var after: String?
    var selected: String?
    if let focused {
      AXUIElementSetMessagingTimeout(focused, 0.25)
      selected = copy(focused, kAXSelectedTextAttribute)
      if let value: String = copy(focused, kAXValueAttribute), let range = selectedRange(focused) {
        let ns = value as NSString
        let loc = min(max(0, range.location), ns.length)
        let end = min(ns.length, loc + max(0, range.length))
        before = ns.substring(to: loc)
        after = ns.substring(from: end)
      }
    }
    let ctx = ScreenContext(appName: name, windowTitle: title, textBefore: before, textAfter: after, selectedText: selected)
    return Focus(pid: app.processIdentifier, element: focused, context: ctx.trimmed, url: browserURL(app))
  }

  /// URL de la pestaña activa en Arc, Chrome o Safari (por AppleScript; pide el permiso de Automatización una vez).
  static func browserURL(_ app: NSRunningApplication?) -> String? {
    guard let id = app?.bundleIdentifier, ToneResolver.isBrowser(id) else { return nil }
    let script = id == "com.apple.Safari"
      ? "tell application id \"\(id)\" to get URL of front document"
      : "tell application id \"\(id)\" to get URL of active tab of front window"
    var error: NSDictionary?
    return NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
  }

  /// Después de pegar: ¿el texto quedó en el campo? nil si el campo no deja leer su contenido.
  static func verify(_ focus: Focus, contains text: String) -> Bool? {
    guard let element = focus.element, let value: String = copy(element, kAXValueAttribute) else { return nil }
    let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(24))
    guard !probe.isEmpty else { return nil }
    return value.contains(probe)
  }

  static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
    return value as? T
  }

  static func selectedRange(_ element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
  }
}
