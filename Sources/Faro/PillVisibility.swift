import AppKit
import ApplicationServices
import CoreGraphics
import FaroCore

/// Decide si la píldora en reposo estorba: app en pantalla completa o app de video al frente.
@MainActor
enum PillVisibility {
  static let videoApps: Set<String> = [
    "com.westbridge.stremio5-mac", "com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX",
    "com.apple.TV", "com.netflix.Netflix", "com.firecore.infuse",
  ]

  static let browsers: Set<String> = [
    "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome", "com.apple.Safari",
    "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera", "app.zen-browser.zen",
  ]

  /// Partes de la ruta del ejecutable de un juego. Minecraft Java corre como un proceso `java` sin bundle,
  /// instalado por su launcher (oficial, Modrinth, Prism, CurseForge, Lunar).
  static let gamePaths = ["minecraft", "modrinthapp", "prismlauncher", "curseforge", "lunarclient"]

  /// Un juego al frente, en pantalla completa o en ventana: la isla no se activa mientras se juega.
  static func isPlayingGame() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    let path = app.executableURL?.path.lowercased() ?? ""
    if gamePaths.contains(where: { path.contains($0) }) { return true }
    // Con un Java instalado aparte, se reconoce por el título de la ventana («Minecraft* 26.2 - Un jugador»).
    if app.bundleIdentifier == nil, path.hasSuffix("/java") {
      return windowTitles(pid: app.processIdentifier).contains { $0.hasPrefix("Minecraft") }
    }
    return false
  }

  static func windowTitles(pid: pid_t) -> [String] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid ? $0[kCGWindowName as String] as? String : nil }
  }

  /// En apps de video siempre; en un navegador en pantalla completa con YouTube, Netflix o similar, también; en el resto de pantallas completas solo si se pide (en la isla el notch queda libre
  /// en pantalla completa, así que por defecto se sigue viendo).
  static func shouldHide(inFullscreen: Bool) -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    if let id = app.bundleIdentifier, videoApps.contains(id) { return true }
    guard isFullscreen(pid: app.processIdentifier) else { return false }
    if inFullscreen { return true }
    if let id = app.bundleIdentifier, browsers.contains(id), let title = focusedWindowTitle(pid: app.processIdentifier) {
      return VideoSites.isWatching(title: title)
    }
    return false
  }

  /// Título de la ventana activa de la app (con Accesibilidad): en un navegador, el de la pestaña.
  static func focusedWindowTitle(pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window
    else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
    else { return nil }
    return title as? String
  }

  /// Una ventana normal de la app que ocupa toda una pantalla.
  static func isFullscreen(pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    let screens = NSScreen.screens.map { $0.frame.size }
    for w in list {
      guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
        let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"]
      else { continue }
      if screens.contains(where: { abs($0.width - width) < 2 && abs($0.height - height) < 2 }) { return true }
    }
    return false
  }
}
