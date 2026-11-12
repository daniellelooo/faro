import AppKit
import FaroCore
import ServiceManagement
import SwiftUI

/// Estado del motor que muestra la interfaz.
enum EngineStatus: Equatable {
  case loading, ready, failed(String)
}

@MainActor @Observable
final class AppModel {
  var engine: EngineStatus = .loading
  var historyVersion = 0
  var lastResult: HistoryEntry?
  var requestedPane: Pane?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let settings = AppSettings()
  let model = AppModel()
  let history = HistoryStore()
  let server = WhisperServer()
  let recorder = AudioRecorder()
  let hotkey = HotkeyMonitor()
  let overlay = OverlayPanel()
  /// La clave se lee del Llavero una sola vez (o al guardarla en Ajustes), no en cada dictado.
  var apiKey: String? {
    didSet { cleaner = AnthropicCleaner(apiKey: apiKey) }
  }
  private var cleaner = AnthropicCleaner(apiKey: nil)
  private lazy var transcriber = WhisperServerTranscriber(server: server)
  var transcriberForMeetings: WhisperServerTranscriber { transcriber }
  let meetings = MeetingController()
  let music = NowPlayingService()
  let claude = ClaudeMonitor()
  let brew = BrewService()
  let clipboard = ClipboardService()
  let shelf = ShelfService()
  let quick = QuickTools()
  let keyboard = KeyboardCleaner()
  let displays = DisplayController()
  let mediaKeys = MediaKeyMonitor()
  let scroll = ScrollReverser()
  let mixer = AppVolumeMixer()
  private var brewTimer: Timer?

  private var statusItem: NSStatusItem!
  private var window: NSWindow?
  private var focus: AXReader.Focus?
  private var startedApp: NSRunningApplication?
  private var stream: StreamingDictation?
  private var levelTimer: Timer?
  private var termSource: DispatchSourceSignal?
  private var pillTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Un cierre forzado (SIGTERM) pasa por terminate para apagar el motor y no dejar procesos huérfanos.
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    termSource = source

    if let exe = Bundle.main.executablePath { ClaudeIntegration.repairExecutablePath(exe) }
    apiKey = KeychainStore.read(service: KeychainStore.apiKeyService)
    setupStatusItem()
    setupMainMenu()
    overlay.showIdle = settings.showIdlePill
    overlay.followsPointer = settings.islandFollowsPointer
    overlay.state.idleLeft = settings.idleLeft
    overlay.state.idleRight = settings.idleRight
    overlay.style = settings.indicatorStyle
    overlay.state.music = music
    overlay.state.claude = claude
    overlay.state.app = self
    overlay.show(.hidden)
    music.onTrackChange = { [weak self] np in
      guard let self, !self.overlay.idleSuppressed, !self.overlay.state.dictationActive else { return }
      self.overlay.showLiveNotice(.track(title: np.title, artist: np.artist))
    }
    music.start()
    claude.onNotice = { [weak self] n in
      // Viendo un video tampoco salta el aviso; queda en Inicio, en lo que te espera.
      guard let self, !self.overlay.state.dictationActive, !self.overlay.idleSuppressed else { return }
      self.overlay.showLiveNotice(.claude(n), seconds: 4.5)
    }
    claude.start()
    clipboard.start()
    quick.onTimerFinished = { [weak self] in
      NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
      self?.overlay.showLiveNotice(.text("Terminó el temporizador", symbol: "timer"), seconds: 6)
    }
    quick.onColorPicked = { [weak self] hex in
      self?.overlay.showLiveNotice(.text("Copiado \(hex)", symbol: "eyedropper.halffull"), seconds: 2.5)
    }
    brew.onUpgradeFinished = { [weak self] text in self?.overlay.showLiveNotice(.text(text, symbol: "shippingbox.fill")) }
    brew.check()
    brewTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.brew.check() }
    }
    // Revisar cada segundo (y al cambiar de app) si la píldora en reposo debería ocultarse.
    let refreshPill = { [weak self] in
      guard let self else { return }
      let playing = PillVisibility.isPlayingGame()
      self.scroll.gameInFront = playing
      self.overlay.idleSuppressed = playing
        || (self.settings.hidePillWhenWatching
          && PillVisibility.shouldHide(inFullscreen: self.settings.hideInFullscreen || self.settings.indicatorStyle == .pill, islandScreen: self.overlay.activeScreen))
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { refreshPill() }
    }
    pillTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { refreshPill() } }
    Task {
      do {
        try await server.start()
        model.engine = .ready
        // `--retranscribir <id>`: vuelve a transcribir esa reunión al arrancar (para revisar el proceso).
        if let i = CommandLine.arguments.firstIndex(of: "--retranscribir"), i + 1 < CommandLine.arguments.count,
          let id = UUID(uuidString: CommandLine.arguments[i + 1]) {
          await meetings.retranscribe(id)
        }
        // `--importar <ruta>`: importa ese audio como reunión (para revisar el proceso).
        if let i = CommandLine.arguments.firstIndex(of: "--importar"), i + 1 < CommandLine.arguments.count {
          await meetings.importAudio(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
      } catch {
        model.engine = .failed(error.localizedDescription)
      }
      updateMenu()
    }
    meetings.app = self
    hotkey.onAction = { [weak self] in self?.handle($0) }
    _ = hotkey.start()
    mediaKeys.enabled = settings.volumeBrightnessInIsland
    mediaKeys.onKey = { [weak self] key, fine in self?.handleMediaKey(key, fine: fine) ?? false }
    _ = mediaKeys.start()
    scroll.inversion = settings.scrollInversion
    scroll.steppedInGames = settings.steppedScrollInGames
    mixer.start()
    displays.refresh()
    if !Permissions.microphone {
      Task { _ = await Permissions.requestMicrophone() }
    }
    // `--seccion reuniones` (o historial, ajustes…) abre la ventana en esa sección: útil para revisar la interfaz.
    if let i = CommandLine.arguments.firstIndex(of: "--seccion"), i + 1 < CommandLine.arguments.count {
      let name = CommandLine.arguments[i + 1].lowercased()
      model.requestedPane = Pane.allCases.first { $0.title.lowercased() == name }
    }
    // `--abrir-isla bandeja` (o portapapeles, herramientas…) abre la isla en esa página: para revisar la interfaz.
    if let i = CommandLine.arguments.firstIndex(of: "--abrir-isla"), i + 1 < CommandLine.arguments.count {
      let name = CommandLine.arguments[i + 1].lowercased()
      if let page = IslandPage.allCases.first(where: { $0.title.lowercased() == name }) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          self.overlay.state.page = page
          self.overlay.expand()
        }
        return
      }
    }
    if CommandLine.arguments.contains("--demo-indicador") {
      runIndicatorDemo()
      return
    }
    openWindow()
  }

  /// `--demo-indicador`: pasa el indicador por sus estados para revisarlo sin dictar.
  private func runIndicatorDemo() {
    Task {
      func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
      // Datos simulados: una canción sonando y una sesión de Claude trabajando.
      music.stop()
      music.artwork = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")!)
      music.current = NowPlaying(title: "Reason (Bonobo Rework)", artist: "Kamaal Williams", album: "", duration: 236, elapsed: 61,
        rate: 1, timestamp: Date(), playing: true, appBundleID: "com.spotify.client")
      claude.board.apply(HookEvent(name: "UserPromptSubmit", sessionID: "demo", cwd: NSHomeDirectory() + "/faro", date: Date().addingTimeInterval(-134), message: nil))
      overlay.state.level = 0.7
      overlay.show(.listening)
      await wait(2.5)
      overlay.show(.hidden)
      await wait(2.5)  // actividad: música + Claude
      overlay.showLiveNotice(.track(title: "Reason (Bonobo Rework)", artist: "Kamaal Williams"))
      await wait(2.5)
      overlay.showLiveNotice(.claude(.finished(project: "faro", seconds: 194)))
      await wait(3)
      for page in IslandPage.allCases {
        overlay.state.page = page
        overlay.expand()
        await wait(2.5)
      }
      overlay.collapse()
    }
  }

  /// Abrir Faro otra vez (Dock, Spotlight, Finder) muestra la ventana.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openWindow()
    return true
  }

  /// Cerrar la ventana no cierra Faro: sigue escuchando la tecla Fn.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    meetings.finishForQuit()
    music.stop()
    keyboard.stop()
    displays.restoreOnQuit()
    mixer.stopAll()
    let server = self.server
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
      await server.stop()
      sem.signal()
    }
    _ = sem.wait(timeout: .now() + 1)
  }

  // MARK: Dictado

  private func handle(_ action: FnStateMachine.Action) {
    guard !settings.paused else { return }
    if meetings.isRecording {
      if action == .startRecording { overlay.show(.notice("Estás grabando una reunión")) }
      return
    }
    switch action {
    case .startRecording: startRecording()
    case .enterHandsFree:
      overlay.state.handsFree = true
      overlay.show(.listening)
    case .cancelRecording: cancelRecording()
    case .stopAndProcess: stopAndProcess()
    }
  }

  private func startRecording() {
    guard case .ready = model.engine else {
      overlay.show(.notice(engineMessage))
      return
    }
    let app = NSWorkspace.shared.frontmostApplication
    startedApp = app
    focus = AXReader.capture(app: app)
    let stream = StreamingDictation(transcriber: transcriber, sampleRate: AudioRecorder.sampleRate, dictionary: settings.dictionary)
    self.stream = stream
    recorder.onSamples = { stream.append($0) }
    do {
      try recorder.start()
    } catch {
      overlay.show(.notice("No se pudo usar el micrófono"))
      return
    }
    if !settings.localOnly { cleaner.warmUp() }
    overlay.state.handsFree = false
    overlay.show(.listening)
    levelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.overlay.state.level = self.recorder.level
      }
    }
  }

  private func cancelRecording() {
    levelTimer?.invalidate()
    recorder.onSamples = nil
    _ = recorder.stop()
    stream = nil
    overlay.show(.hidden)
  }

  private var engineMessage: String {
    switch model.engine {
    case .loading: return "El motor de voz todavía está cargando"
    case .failed(let m): return m
    case .ready: return ""
    }
  }

  private func stopAndProcess() {
    levelTimer?.invalidate()
    recorder.onSamples = nil
    let samples = recorder.stop()
    guard let stream else { return }
    // El último dictado queda en disco (se sobrescribe) para revisar qué oyó Faro cuando un dictado sale raro.
    let lastAudio = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Faro/ultimo-dictado.wav")
    let wav = WAVEncoder.encode(samples: samples, sampleRate: AudioRecorder.sampleRate)
    let note = "\(Date()) sistema: \(MicInfo.defaultInputName ?? "?") · usado: \(recorder.formats.joined(separator: " → ")) · " +
      String(format: "%.1f s, pico %.3f\n", Double(samples.count) / Double(AudioRecorder.sampleRate), recorder.peak)
    DispatchQueue.global(qos: .utility).async {
      try? wav.write(to: lastAudio)
      let log = lastAudio.deletingLastPathComponent().appendingPathComponent("dictado.log")
      if let h = try? FileHandle(forWritingTo: log) {
        h.seekToEndOfFile()
        h.write(Data(note.utf8))
        try? h.close()
      } else {
        try? note.write(to: log, atomically: true, encoding: .utf8)
      }
    }
    // Sin audio, o con ceros exactos, el micrófono no está mandando nada: se avisa en vez de ocultar en silencio.
    if recorder.chunks == 0 || recorder.peak == 0 {
      self.stream = nil
      overlay.show(.notice("El micrófono no mandó audio (\(MicInfo.defaultInputName ?? "entrada desconocida"))"))
      return
    }
    self.stream = nil
    overlay.show(.processing)
    let focus = self.focus ?? AXReader.capture(app: NSWorkspace.shared.frontmostApplication)
    let app = startedApp
    let tone = settings.styles.tone(bundleID: app?.bundleIdentifier, url: focus.url)
    let pipeline = DictationPipeline(transcriber: transcriber, cleaner: cleaner, dictionary: settings.dictionary)
    let localOnly = settings.localOnly
    let words = settings.words
    Task {
      let clock = ContinuousClock()
      let start = clock.now
      do {
        if Double(DictationPipeline.trimSilence(samples, sampleRate: AudioRecorder.sampleRate).count) / Double(AudioRecorder.sampleRate) < DictationPipeline.minimumSpeech {
          overlay.show(.hidden)
          return
        }
        let raw = try await stream.finish()
        var timings = DictationTimings()
        timings.transcription = DictationPipeline.seconds(clock.now - start)
        let result = await pipeline.cleanup(raw: raw, tone: tone, context: focus.context, localOnly: localOnly, timings: timings, start: start)
        guard !result.skipped else {
          overlay.show(.hidden)
          return
        }
        let text = InsertionAdjuster.adjust(result.final, before: focus.context.textBefore ?? "", after: focus.context.textAfter ?? "", properNouns: words)
        let outcome = await PasteInjector.paste(text, into: focus.pid)
        var verified: Bool?
        switch outcome {
        case .pasted:
          try? await Task.sleep(for: .milliseconds(120))
          verified = AXReader.verify(focus, contains: text) ?? true
        case .notRequested: verified = false
        case .noPermission: verified = false
        }
        let entry = HistoryEntry(date: Date(), raw: result.raw, final: text.trimmingCharacters(in: .whitespaces), app: focus.context.appName,
          usedFallback: result.usedFallback, seconds: result.timings.total, bundleID: app?.bundleIdentifier, verified: verified, tone: tone)
        history.add(entry)
        model.lastResult = entry
        model.historyVersion += 1
        switch outcome {
        case .noPermission: overlay.show(.notice("Texto copiado: falta el permiso de Accesibilidad"))
        case .notRequested: overlay.show(.notice("No se pudo pegar: el texto quedó copiado"))
        case .pasted:
          if result.usedFallback, let reason = result.fallbackReason {
            overlay.show(.notice("Sin limpiar: \(reason.lowercased())"))
          } else {
            overlay.show(.hidden)
          }
        }
      } catch {
        overlay.show(.notice(error.localizedDescription))
      }
    }
  }

  // MARK: Menú de la barra

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Faro")
    updateMenu()
  }

  func updateMenu() {
    let menu = NSMenu()
    let title: String
    switch model.engine {
    case .ready: title = settings.paused ? "Dictado en pausa" : "Mantén Fn para dictar"
    case .loading: title = "Cargando motor de voz…"
    case .failed(let m): title = m
    }
    let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())
    let open = NSMenuItem(title: "Abrir Faro", action: #selector(openWindowAction), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    let meeting = NSMenuItem(title: meetings.isRecording ? "Terminar la reunión" : "Grabar una reunión", action: #selector(toggleMeeting), keyEquivalent: "")
    meeting.target = self
    menu.addItem(meeting)
    if meetings.isRecording {
      let pause = NSMenuItem(title: meetings.isPaused ? "Reanudar la grabación" : "Pausar la grabación", action: #selector(togglePauseMeeting), keyEquivalent: "")
      pause.target = self
      menu.addItem(pause)
    }
    let pause = NSMenuItem(title: "Pausar dictado", action: #selector(togglePause), keyEquivalent: "")
    pause.state = settings.paused ? .on : .off
    pause.target = self
    menu.addItem(pause)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Salir de Faro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu
  }

  @objc private func togglePause() {
    settings.paused.toggle()
    updateMenu()
  }

  @objc private func openWindowAction() { openWindow() }

  func toggleMeetingFromIsland() {
    if meetings.isRecording {
      Task {
        await meetings.stop()
        updateMenu()
      }
    } else {
      model.requestedPane = .meetings
      openWindow()
    }
  }

  @objc private func togglePauseMeeting() { meetings.togglePause() }

  @objc private func toggleMeeting() {
    if meetings.isRecording {
      Task {
        await meetings.stop()
        updateMenu()
      }
    } else {
      model.requestedPane = .meetings
      openWindow()
    }
  }

  func openWindow() {
    if window == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
      w.title = "Faro"
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.isReleasedWhenClosed = false
      w.minSize = NSSize(width: 780, height: 520)
      w.contentView = NSHostingView(rootView: MainWindowView(app: self, settings: settings, model: model))
      w.center()
      w.setFrameAutosaveName("FaroVentana")
      w.delegate = self
      // Abrir Faro la trae al escritorio donde estás, aunque estés en otra app a pantalla completa.
      w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
      window = w
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  var launchAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      do {
        if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch {}
    }
  }

  func saveAPIKey(_ key: String) -> Bool {
    guard KeychainStore.write(service: KeychainStore.apiKeyService, value: key) else { return false }
    apiKey = key
    return true
  }
}

extension AppDelegate {
  /// Menú principal estándar. Sin el menú Edición, Cmd+C / Cmd+V no llegan a los campos de texto.
  func setupMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Ocultar Faro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Salir de Faro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edición")
    edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let window = NSMenu(title: "Ventana")
    window.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = window
    main.addItem(windowItem)
    NSApp.windowsMenu = window
    NSApp.mainMenu = main
  }
}

extension AppDelegate {
  /// Lo que merece tu atención ahora, de lo más urgente a lo menos.
  func attentionItems() -> [AttentionItem] {
    var items: [AttentionItem] = []
    let claude = self.claude
    for s in claude.board.sessions.values where s.state == .waiting {
      items.append(AttentionItem(symbol: "hand.raised.fill", color: .orange, text: "Claude te espera en \(s.project)", url: nil))
    }
    if let f = claude.limits?.fiveHour, f.percent >= 80 {
      let reset = f.resetsAt.map { ", se reinicia " + $0.formatted(.relative(presentation: .named)) } ?? ""
      items.append(AttentionItem(symbol: "gauge.with.dots.needle.100percent", color: f.percent >= 95 ? .red : .orange,
        text: "Llevas \(Int(f.percent.rounded())) % del límite de 5 horas\(reset)", url: nil))
    }
    for p in claude.projects.projects {
      guard let h = p.health else { continue }
      if h.ci == .failure { items.append(AttentionItem(symbol: "xmark.octagon.fill", color: .red, text: "CI en rojo en \(p.name) (\(p.git?.branch ?? "rama actual"))", url: h.ciURL)) }
      if h.deploy == .failure { items.append(AttentionItem(symbol: "xmark.octagon.fill", color: .red, text: "Falló el despliegue de \(p.name)", url: h.deployURL)) }
      for pr in h.pullRequests where pr.checks == .failure {
        items.append(AttentionItem(symbol: "arrow.triangle.pull", color: .red, text: "PR #\(pr.number) de \(p.name) con checks en rojo", url: pr.url))
      }
    }
    if quick.timerRunning {
      items.append(AttentionItem(symbol: "timer", color: .mint, text: "Temporizador: termina a las " +
        Date().addingTimeInterval(quick.timerRemaining()).formatted(date: .omitted, time: .shortened), url: nil))
    }
    return items
  }}

extension AppDelegate {
  /// Teclas de volumen y brillo: Faro cambia el nivel y lo muestra en la isla en vez del indicador de macOS.
  func handleMediaKey(_ key: MediaKeyMonitor.Key, fine: Bool) -> Bool {
    // Sin la isla (píldora o barra de menú) se deja el indicador de macOS.
    guard settings.indicatorStyle == .island, !overlay.idleSuppressed || overlay.state.hud != nil else { return false }
    switch key {
    case .volumeUp, .volumeDown:
      guard let current = SystemVolume.volume else { return false }
      let muted = SystemVolume.isMuted
      // En silencio, subir quita el silencio y vuelve al nivel que había; bajar lo deja en silencio.
      var v = muted ? current : LevelSteps.next(current, up: key == .volumeUp, fine: fine)
      if muted && key == .volumeUp {
        SystemVolume.setMuted(false)
        if v == 0 { v = LevelSteps.next(0, up: true, fine: fine) }
      }
      SystemVolume.setVolume(v)
      // Al llegar a cero se silencia, como hace macOS.
      if v == 0 { SystemVolume.setMuted(true) }
      overlay.showHUD(LevelHUD(kind: .volume, value: v, muted: v == 0 || (muted && key == .volumeDown), label: SystemVolume.outputName))
      return true
    case .mute:
      let m = !SystemVolume.isMuted
      SystemVolume.setMuted(m)
      overlay.showHUD(LevelHUD(kind: .volume, value: SystemVolume.volume ?? 0, muted: m, label: SystemVolume.outputName))
      return true
    case .brightnessUp, .brightnessDown:
      guard let d = displays.displayUnderPointer else { return false }
      let v = LevelSteps.next(d.brightness, up: key == .brightnessUp, fine: fine)
      displays.setBrightness(v, for: d.id)
      overlay.showHUD(LevelHUD(kind: .brightness, value: v, label: d.isBuiltIn ? "Pantalla del Mac" : d.name))
      return true
    }
  }
}
