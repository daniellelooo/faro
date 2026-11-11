import AppKit
import ApplicationServices
import CoreGraphics
import FaroCore
import IOKit.pwr_mgt

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
  static func shouldHide(inFullscreen: Bool, islandScreen: NSScreen?) -> Bool {
    frontAppHides(inFullscreen: inFullscreen) || (islandScreen.map(videoCovers) ?? false)
  }

  /// Un video en pantalla completa en esa pantalla aunque el foco esté en otra app, por ejemplo en la otra pantalla.
  private static func videoCovers(_ screen: NSScreen) -> Bool {
    NSWorkspace.shared.runningApplications.contains { app in
      guard let id = app.bundleIdentifier, browsers.contains(id) else { return false }
      return window(of: app.processIdentifier, covers: screen) && keepsDisplayAwake(pid: app.processIdentifier)
    }
  }

  private static func frontAppHides(inFullscreen: Bool) -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    if let id = app.bundleIdentifier, videoApps.contains(id) { return true }
    let pid = app.processIdentifier
    let browser = app.bundleIdentifier.map(browsers.contains) ?? false
    guard isFullscreen(pid: pid) || (browser && focusedWindowIsFullscreen(pid: pid)) else { return false }
    if inFullscreen { return true }
    guard browser else { return false }
    // Un navegador en pantalla completa es para navegar (Dia o Arc se usan así todo el día): la isla solo se oculta
    // con un video reproduciéndose, que mantiene la pantalla encendida. El título por sí solo no basta: ocultaba la
    // isla en cualquier página de YouTube. Se recuerda el título unos minutos para que no vuelva a salir al pausar.
    let title = focusedWindowTitle(pid: pid) ?? ""
    if keepsDisplayAwake(pid: pid) {
      lastVideo = (title, Date())
      return true
    }
    if let last = lastVideo, !title.isEmpty, title == last.title, Date().timeIntervalSince(last.at) < 300 { return true }
    return false
  }

  private static var lastVideo: (title: String, at: Date)?

  /// La app tiene pedido al sistema que no se apague la pantalla (no necesita ningún permiso).
  static func keepsDisplayAwake(pid: pid_t) -> Bool {
    var out: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess, let all = out?.takeRetainedValue() as NSDictionary?,
      let assertions = all[NSNumber(value: pid)] as? [[String: Any]]
    else { return false }
    return assertions.contains { a in
      guard let type = a["AssertType"] as? String else { return false }
      return type == "NoDisplaySleepAssertion" || type == "PreventUserIdleDisplaySleep"
    }
  }

  /// En la pantalla del Mac la ventana en pantalla completa queda debajo del notch y no mide lo que la pantalla.
  static func focusedWindowIsFullscreen(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window
    else { return false }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success
    else { return false }
    return (value as? Bool) ?? false
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

  /// Un navegador al frente con una ventana que ocupa exactamente esa pantalla.
  static func browserFullscreen(on screen: NSScreen) -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, browsers.contains(id)
    else { return false }
    return window(of: app.processIdentifier, covers: screen)
  }

  private static func window(of pid: pid_t, covers screen: NSScreen) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let primary = NSScreen.screens.first
    else { return false }
    // CGWindow cuenta desde arriba de la pantalla principal; NSScreen, desde abajo.
    let target = CGRect(x: screen.frame.minX, y: primary.frame.height - screen.frame.maxY,
      width: screen.frame.width, height: screen.frame.height)
    return list.contains { w in
      guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
        let b = w[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"],
        let width = b["Width"], let height = b["Height"]
      else { return false }
      return abs(x - target.minX) < 2 && abs(y - target.minY) < 2 && abs(width - target.width) < 2 && abs(height - target.height) < 2
    }
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
