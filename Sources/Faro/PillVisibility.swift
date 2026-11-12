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
      // Un video sonando en una ventana que ocupa la pantalla no basta (Arc o Dia se usan así todo el día, y YouTube
      // reproduce las vistas previas al pasar el puntero): la página tiene que ocupar toda la ventana.
      let pid = app.processIdentifier
      return window(of: pid, covers: screen) && keepsDisplayAwake(pid: pid) && webAreaFillsWindow(pid: pid)
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
    // Dia o Arc se usan en pantalla completa todo el día, así que eso no basta, ni el título, ni que suene un video.
    // Un video en pantalla completa (o una presentación) hace que la página ocupe toda la ventana, sin pestañas ni
    // barra de dirección: esa es la señal.
    let fills = webAreaFillsWindow(pid: pid)
    logBrowser(fills)
    return fills
  }

  /// La página web ocupa toda la ventana activa del navegador (contenido en pantalla completa).
  static func webAreaFillsWindow(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    // Dia, Chrome y los demás basados en Chromium no muestran la página a Accesibilidad hasta que una app lo pide.
    // Se pide solo cuando hay un video sonando (es cuando importa), una vez por proceso.
    if !manualAccessibility.contains(pid), keepsDisplayAwake(pid: pid) {
      manualAccessibility.insert(pid)
      AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value
    else { return false }
    let window = value as! AXUIElement
    guard let windowFrame = frame(of: window), windowFrame.width > 0 else { return false }
    // Esto corre cada segundo: se reusa el área web encontrada y solo se busca otra si esa ya no existe (otra pestaña).
    if let cached = cachedWebArea, cached.pid == pid, let web = frame(of: cached.element), web.width > 0 {
      lastWebArea = (web, windowFrame)
      return web.width >= windowFrame.width - 2 && web.height >= windowFrame.height - 2
    }
    cachedWebArea = nil
    // Búsqueda a lo ancho con tope: el árbol de una página puede ser enorme y el área web está cerca de la raíz.
    var queue = [window]
    var visited = 0
    while !queue.isEmpty, visited < 300 {
      let element = queue.removeFirst()
      visited += 1
      var role: CFTypeRef?
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
      if (role as? String) == "AXWebArea" {
        guard let web = frame(of: element) else { return false }
        cachedWebArea = (pid, element)
        lastWebArea = (web, windowFrame)
        return web.width >= windowFrame.width - 2 && web.height >= windowFrame.height - 2
      }
      var children: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
        let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
    }
    return false
  }

  /// Dirección de la página activa del navegador (con Accesibilidad), si se puede leer.
  static func focusedPageURL(pid: pid_t) -> URL? {
    _ = webAreaFillsWindow(pid: pid)  // busca y guarda el área web de la ventana activa
    guard let cached = cachedWebArea, cached.pid == pid else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(cached.element, "AXURL" as CFString, &value) == .success else { return nil }
    if let url = value as? URL { return url }
    return (value as? String).flatMap(URL.init(string:))
  }

  /// En YouTube, las páginas donde se ve un video; en el resto (portada, búsqueda, canal) lo que suena es una vista previa.
  static func isYouTubeBrowsing(_ url: URL?) -> Bool {
    guard let url, let host = url.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
    let watching = ["/watch", "/shorts", "/live", "/embed", "/playlist"]
    return !watching.contains { url.path.hasPrefix($0) }
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    var pos: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success
    else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
  }

  private static var lastWebArea: (web: CGRect, window: CGRect)?
  private static var manualAccessibility: Set<pid_t> = []
  private static var cachedWebArea: (pid: pid_t, element: AXUIElement)?
  private static var lastLogged: Bool?

  /// Deja en un archivo cada cambio de decisión con las medidas, para revisar casos raros sin adivinar.
  private static func logBrowser(_ hides: Bool) {
    guard hides != lastLogged else { return }
    lastLogged = hides
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Faro/isla-navegador.log")
    let m = lastWebArea.map { "web \(Int($0.web.width))x\(Int($0.web.height)) ventana \(Int($0.window.width))x\(Int($0.window.height))" } ?? "sin área web"
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    let line = "\(Date()) \(front) \(hides ? "oculta" : "visible") \(m)\n"
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile()
      h.write(Data(line.utf8))
      try? h.close()
    } else {
      try? line.write(to: url, atomically: true, encoding: .utf8)
    }
  }

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
