import AppKit
import FaroCore
import SwiftUI

/// Cómo se muestra el estado en pantalla.
enum IndicatorStyle: String, CaseIterable, Identifiable {
  /// Isla dinámica en el notch: actividades, avisos y panel al pasar el puntero.
  case island
  /// Píldora abajo al centro, solo para el dictado.
  case pill
  /// Solo el ícono de la barra de menú.
  case menuBar
  var id: String { rawValue }
  var title: String {
    switch self {
    case .island: return "Isla en el notch"
    case .pill: return "Píldora abajo"
    case .menuBar: return "Solo barra de menú"
    }
  }
}

enum IslandPage: String, CaseIterable, Identifiable {
  case music, agents, controls, shelf, tools
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .music: return "music.note"
    case .agents: return "sparkles"
    case .controls: return "slider.horizontal.3"
    case .shelf: return "tray.full"
    case .tools: return "square.grid.2x2"
    }
  }
  var title: String {
    switch self {
    case .music: return "Música"
    case .agents: return "Agentes"
    case .controls: return "Controles"
    case .shelf: return "Bandeja"
    case .tools: return "Herramientas"
    }
  }
}

/// Indicador de volumen o brillo que reemplaza al de macOS.
struct LevelHUD: Equatable {
  enum Kind: Equatable { case volume, brightness }
  var kind: Kind
  var value: Float
  var muted = false
  /// Salida de audio o pantalla.
  var label: String

  var symbol: String {
    switch kind {
    case .brightness: return value < 0.34 ? "sun.min.fill" : "sun.max.fill"
    case .volume:
      if muted || value == 0 { return "speaker.slash.fill" }
      return value < 0.34 ? "speaker.wave.1.fill" : (value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }
  }
}

/// Aviso breve de la isla (aparte de los avisos del dictado).
enum LiveNotice: Equatable {
  case track(title: String, artist: String)
  case claude(ActivityNotice)
  case text(String, symbol: String)
}

@MainActor @Observable
final class OverlayState {
  enum Phase: Equatable { case hidden, idle, listening, processing, meeting, notice(String) }
  var phase: Phase = .hidden
  var level: Float = 0
  var handsFree = false
  var meetingElapsed: Double = 0
  var meetingPaused = false
  var style: IndicatorStyle = .island
  var notchWidth: CGFloat = 0
  var notchHeight: CGFloat = 0

  // Isla dinámica
  var expanded = false
  /// El puntero está sobre el notch (la isla crece un poco antes de abrirse).
  var hovering = false
  var page: IslandPage = .music
  enum ShelfTab: CaseIterable { case files, clipboard
    var title: String { self == .files ? "Archivos" : "Portapapeles" }
  }
  var shelfTab: ShelfTab = .files
  var liveNotice: LiveNotice?
  /// En pantalla completa o en apps de video las actividades (música, Claude) no se muestran cerradas.
  var suppressActivities = false
  /// La isla se queda visible (un poco más ancha que el notch) aunque no pase nada.
  var idleVisible = true
  var hud: LevelHUD?
  /// Se está arrastrando un archivo sobre la isla.
  var dropTargeting = false
  var idleLeft: IdleItem = .limit5h
  var idleRight: IdleItem = .costToday
  /// Cada hombro de la isla en reposo mide lo que pida el elemento más ancho (los dos iguales, para que quede centrada).
  var idleShoulder: CGFloat {
    let w = max(idleLeft.width, idleRight.width)
    return w == 0 ? 18 : w + 22
  }
  @ObservationIgnored weak var music: NowPlayingService?
  @ObservationIgnored weak var claude: ClaudeMonitor?
  @ObservationIgnored weak var app: AppDelegate?

  var dictationActive: Bool {
    switch phase {
    case .hidden, .idle: return false
    default: return true
    }
  }
}

/// Panel que no toma el foco: siempre encima, en todos los escritorios, también sobre la barra de menú.
final class IndicatorPanel: NSPanel {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
  override var canBecomeKey: Bool { false }
}

@MainActor
final class OverlayPanel {
  let state = OverlayState()
  private let panel: IndicatorPanel
  private var noticeTask: Task<Void, Never>?
  private var liveNoticeTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  private var hoverIntent = HoverIntent()
  private var browserFullscreenInBand: Bool?
  private static let fullscreenEdgeHeight: CGFloat = 3
  private var monitors: [Any] = []

  static let panelSize = NSSize(width: 720, height: 320)
  static let expandedSize = CGSize(width: 640, height: 262)

  /// La isla se muda a la pantalla donde está el puntero (con un monitor externo); si no, se queda en la del Mac.
  var followsPointer = true {
    didSet { position() }
  }
  /// Pantalla donde está la isla ahora.
  private(set) var activeScreen: NSScreen?

  var showIdle = true {
    didSet { state.idleVisible = showIdle && !idleSuppressed }
  }
  var idleSuppressed = false {
    didSet {
      state.suppressActivities = idleSuppressed
      if idleSuppressed { state.hovering = false }
      state.idleVisible = showIdle && !idleSuppressed
      if oldValue != idleSuppressed, !state.dictationActive { show(.hidden) }
    }
  }
  var style: IndicatorStyle = .island {
    didSet {
      state.style = style
      collapse()
      show(state.dictationActive ? state.phase : .hidden)
    }
  }

  init() {
    panel = IndicatorPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.contentView = NSHostingView(rootView: IndicatorView(state: state))
    installHover()
    // Conectar o desconectar un monitor (o cambiar la resolución) recoloca la isla.
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.position() }
    }
  }

  // MARK: Dictado

  func show(_ phase: OverlayState.Phase) {
    noticeTask?.cancel()
    var phase = phase
    if phase == .hidden, style == .pill, showIdle, !idleSuppressed { phase = .idle }
    if phase != .hidden && phase != .idle { collapse() }
    withAnimation(.spring(duration: 0.32, bounce: 0.25)) { state.phase = phase }
    position()
    if style == .menuBar {
      panel.orderOut(nil)
      return
    }
    if style == .pill && phase == .hidden {
      let p = panel
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        if self?.state.phase == .hidden { p.orderOut(nil) }
      }
    } else {
      // La isla queda siempre al frente (transparente cuando no hay nada).
      panel.orderFrontRegardless()
    }
    if case .notice = phase {
      noticeTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(2.6))
        if !Task.isCancelled { self?.show(.hidden) }
      }
    }
  }

  // MARK: Volumen y brillo

  private var hudTask: Task<Void, Never>?

  func showHUD(_ hud: LevelHUD) {
    guard style == .island else { return }
    hudTask?.cancel()
    if state.hud == nil {
      withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { state.hud = hud }
    } else {
      withAnimation(.easeOut(duration: 0.12)) { state.hud = hud }
    }
    panel.orderFrontRegardless()
    hudTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.4))
      if !Task.isCancelled {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self?.state.hud = nil }
      }
    }
  }

  // MARK: Avisos de la isla

  func showLiveNotice(_ notice: LiveNotice, seconds: Double = 3.5) {
    guard style == .island else {
      if style == .pill, case .text(let t, _) = notice { show(.notice(t)) }
      return
    }
    liveNoticeTask?.cancel()
    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { state.liveNotice = notice }
    panel.orderFrontRegardless()
    liveNoticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      if !Task.isCancelled {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { self?.state.liveNotice = nil }
      }
    }
  }

  // MARK: Abrir al pasar el puntero

  private func installHover() {
    let move: (NSEvent) -> Void = { [weak self] e in
      MainActor.assumeIsolated {
        let dragging = e.type == .leftMouseDragged
        if dragging { self?.dragMoved(NSEvent.mouseLocation) }
        self?.mouseMoved(NSEvent.mouseLocation, dragging: dragging)
      }
    }
    // Un clic en la zona es para lo que hay debajo (la URL, una pestaña): la isla no se abre hasta que el puntero salga.
    let press: (NSEvent) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.pointerPressed() }
    }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: press) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { e in press(e); return e }) { monitors.append(m) }
    // Arrastrar archivos hacia el notch abre la bandeja. La isla solo sabe que hay un arrastre de archivos
    // comparando el portapapeles de arrastre con el que había al apretar el botón.
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.dragStartCount = NSPasteboard(name: .drag).changeCount }
    }) { monitors.append(m) }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.state.dropTargeting else { return }
        withAnimation(.spring(response: 0.3)) { self.state.dropTargeting = false }
      }
    }) { monitors.append(m) }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: move) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in move(e); return e }) { monitors.append(m) }
    // Un clic fuera de la isla abierta la cierra.
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.state.expanded, !self.expandedRect.contains(NSEvent.mouseLocation) else { return }
        self.collapse()
      }
    }) { monitors.append(m) }
  }

  private var dragStartCount = NSPasteboard(name: .drag).changeCount

  private func dragMoved(_ p: NSPoint) {
    guard style == .island, !state.dictationActive, !state.expanded, !idleSuppressed else { return }
    let pb = NSPasteboard(name: .drag)
    guard pb.changeCount != dragStartCount, pb.types?.contains(.fileURL) == true else { return }
    // Zona un poco más generosa que la del puntero: se apunta peor arrastrando.
    if hotRect.insetBy(dx: -40, dy: -24).contains(p) {
      state.page = .shelf
      state.shelfTab = .files
      expand()
    }
  }

  private var hotRect: NSRect {
    guard let screen = activeScreen ?? NSScreen.main else { return .zero }
    // Con la isla en reposo visible, toda la isla (notch más hombros) responde al puntero.
    let w = max(state.notchWidth, 180) + (state.idleVisible ? 2 * state.idleShoulder + 10 : 30)
    // Solo la franja de la barra de menú: un poco más abajo ya está la ventana (la barra de URL o las pestañas).
    let h = max(state.notchHeight, 26)
    return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
  }

  private var expandedRect: NSRect {
    guard let screen = activeScreen ?? NSScreen.main else { return .zero }
    let s = Self.expandedSize
    return NSRect(x: screen.frame.midX - s.width / 2 - 20, y: screen.frame.maxY - s.height - 20, width: s.width + 40, height: s.height + 20)
  }

  static var builtInScreen: NSScreen? {
    NSScreen.screens.first { s in
      let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
      return CGDisplayIsBuiltin(id) != 0
    }
  }

  private func targetScreen() -> NSScreen? {
    if followsPointer, let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) { return s }
    return Self.builtInScreen ?? NSScreen.main ?? NSScreen.screens.first
  }

  /// Si el puntero pasó a otra pantalla, la isla se va con él (no mientras está abierta).
  private func followPointerScreen() {
    guard followsPointer, !state.expanded, let t = targetScreen(), t != activeScreen else { return }
    position()
    if state.hovering { state.hovering = false }
  }

  /// Durante una reunión la isla también se abre (para pausarla o terminarla); durante un dictado, no.
  /// Viendo un video en pantalla completa tampoco: el puntero sube al borde para ver las pestañas, no la isla.
  private var canOpenByHover: Bool {
    style == .island && (!state.dictationActive || state.phase == .meeting)
      && (!idleSuppressed || state.phase == .meeting)
  }

  private func cancelHoverWait() {
    hoverTask?.cancel()
    hoverTask = nil
  }

  private func setHovering(_ inside: Bool) {
    guard inside != state.hovering else { return }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { state.hovering = inside }
    if inside { panel.orderFrontRegardless() }
  }

  /// Con un navegador en pantalla completa la franja de arriba es la barra de URL y las pestañas: ahí solo abre el
  /// borde mismo de la pantalla. Se pregunta una vez al entrar a la franja, no en cada movimiento del puntero.
  private func pointerInOpenZone(_ p: NSPoint) -> Bool {
    // NSMouseInRect cuenta el píxel de más arriba, donde el puntero se queda pegado al subir; contains no.
    guard NSMouseInRect(p, hotRect, false), let screen = activeScreen else {
      browserFullscreenInBand = nil
      return false
    }
    let fullscreen = browserFullscreenInBand ?? (state.phase != .meeting && PillVisibility.browserFullscreen(on: screen))
    browserFullscreenInBand = fullscreen
    return !fullscreen || p.y >= screen.frame.maxY - Self.fullscreenEdgeHeight
  }

  private func pointerPressed() {
    guard !state.expanded, NSMouseInRect(NSEvent.mouseLocation, hotRect, false) else { return }
    hoverIntent.block()
    cancelHoverWait()
    setHovering(false)
  }

  private func mouseMoved(_ p: NSPoint, dragging: Bool) {
    followPointerScreen()
    guard canOpenByHover || state.expanded else { return }
    if state.expanded {
      if expandedRect.contains(p) {
        hoverTask?.cancel()
        hoverTask = nil
      } else if hoverTask == nil {
        hoverTask = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled, let self else { return }
          if !self.expandedRect.contains(NSEvent.mouseLocation) { self.collapse() }
          self.hoverTask = nil
        }
      }
      return
    }
    let inside = pointerInOpenZone(p)
    // Un arrastre (seleccionar la URL, mover una pestaña) nunca abre la isla; los archivos van por dragMoved.
    if dragging {
      if inside { hoverIntent.block() }
      cancelHoverWait()
      setHovering(false)
      return
    }
    switch hoverIntent.moved(to: p, inside: inside) {
    case .none: break
    case .cancelWait: cancelHoverWait()
    case .restartWait:
      cancelHoverWait()
      hoverTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(HoverIntent.dwell))
        guard !Task.isCancelled, let self else { return }
        self.hoverTask = nil
        if self.canOpenByHover, self.pointerInOpenZone(NSEvent.mouseLocation) { self.expand() }
      }
    }
    setHovering(inside && !hoverIntent.blocked)
  }

  func expand() {
    hoverIntent.reset()
    cancelHoverWait()
    position()
    panel.ignoresMouseEvents = false
    panel.orderFrontRegardless()
    liveNoticeTask?.cancel()
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    withAnimation(.spring(response: 0.44, dampingFraction: 0.78)) {
      state.liveNotice = nil
      state.hovering = false
      state.expanded = true
    }
  }

  func collapse() {
    guard state.expanded else { return }
    panel.ignoresMouseEvents = true
    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
      state.expanded = false
      state.hovering = false
    }
  }

  private func position() {
    guard let screen = targetScreen() else { return }
    activeScreen = screen
    let size = Self.panelSize
    switch style {
    case .island, .menuBar:
      if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
        state.notchWidth = screen.frame.width - l.width - r.width
        state.notchHeight = screen.safeAreaInsets.top
      } else {
        state.notchWidth = 0
        state.notchHeight = NSStatusBar.system.thickness
      }
      panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
        width: size.width, height: size.height), display: true)
    case .pill:
      let f = screen.visibleFrame
      panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY, width: size.width, height: size.height), display: true)
    }
  }
}

struct IndicatorView: View {
  let state: OverlayState
  var body: some View {
    switch state.style {
    case .island, .menuBar: IslandView(state: state).environment(\.colorScheme, .dark)
    case .pill: PillView(state: state)
    }
  }
}

// MARK: Píldora abajo

struct PillView: View {
  let state: OverlayState
  var isIdle: Bool { state.phase == .idle }

  var body: some View {
    VStack {
      Spacer(minLength: 0)
      HStack(spacing: 10) {
        switch state.phase {
        case .listening:
          Circle().fill(Color.red).frame(width: 8, height: 8)
          LevelBars(level: state.level)
          Text(state.handsFree ? "Manos libres" : "Escuchando").font(.system(size: 12, weight: .medium))
        case .meeting:
          Circle().fill(Color.red).frame(width: 8, height: 8)
          Text("Grabando reunión").font(.system(size: 12, weight: .medium))
          Text(MeetingClock.text(state.meetingElapsed)).font(.system(size: 12, weight: .medium).monospacedDigit()).opacity(0.8)
        case .processing:
          Spinner()
          Text("Procesando").font(.system(size: 12, weight: .medium))
        case .notice(let text):
          Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
        case .hidden, .idle:
          EmptyView()
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(width: isIdle ? 30 : 220, height: isIdle ? 5 : 44)
      .background(Capsule().fill(Color.black.opacity(isIdle ? 0.35 : 0.82)))
      .opacity(state.phase == .hidden ? 0 : 1)
      .padding(.bottom, isIdle ? 3 : 6)
    }
    .frame(width: OverlayPanel.panelSize.width, height: OverlayPanel.panelSize.height)
  }
}

struct LevelBars: View {
  let level: Float
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 2.5) {
        ForEach(0..<5, id: \.self) { i in
          let wobble = 0.55 + 0.45 * abs(sin(t * 7 + Double(i) * 1.3))
          Capsule().fill(Color.white)
            .frame(width: 2.5, height: 3 + CGFloat(Double(level) * 13 * wobble))
        }
      }
    }
  }
}

/// Barras de música animadas (tamaño fijo, sin depender del nivel de audio).
/// Ecualizador: barras blancas que suben y bajan con dos ondas mezcladas (se ve orgánico, no mecánico).
struct MusicBars: View {
  var playing: Bool
  var color: Color = .white
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(alignment: .center, spacing: 2.5) {
        ForEach(0..<4, id: \.self) { i in
          let d = Double(i)
          let a = 0.5 + 0.5 * sin(t * (5.3 + d * 1.7) + d * 1.9)
          let b = 0.5 + 0.5 * sin(t * (2.1 + d * 0.6) + d * 0.7)
          let level = playing ? 0.25 + 0.75 * (a * 0.65 + b * 0.35) : 0.2
          Capsule().fill(Color.white.opacity(0.92)).frame(width: 2.6, height: 3 + 11 * level)
        }
      }
      .frame(width: 18, height: 14)
    }
  }
}

struct Spinner: View {
  var color: Color = .white
  var body: some View {
    TimelineView(.animation) { context in
      let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
      Circle()
        .trim(from: 0, to: 0.7)
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(angle))
    }
  }
}

enum MeetingClock {
  static func text(_ s: Double) -> String {
    let t = Int(max(0, s))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
  }
}
