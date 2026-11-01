import AppKit
import FaroCore
import SwiftUI

/// Lenguaje visual de la isla abierta: negro puro, tarjetas de cristal muy sutil, una sola medida de esquina y de
/// espacio en todas las páginas.
enum IslandTheme {
  static let card = Color.white.opacity(0.075)
  static let cardStroke = Color.white.opacity(0.1)
  static let secondary = Color.white.opacity(0.55)
  static let tertiary = Color.white.opacity(0.32)
  /// Color de los agentes de IA (coral de Claude, un poco más luminoso sobre negro).
  static let agent = Color(red: 0.96, green: 0.56, blue: 0.42)
  static let radius: CGFloat = 20
  static let gap: CGFloat = 12
}

struct IslandCard<Content: View>: View {
  var padding: CGFloat = 14
  @ViewBuilder var content: Content
  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: IslandTheme.radius, style: .continuous).fill(IslandTheme.card))
      .overlay(RoundedRectangle(cornerRadius: IslandTheme.radius, style: .continuous).strokeBorder(IslandTheme.cardStroke, lineWidth: 0.5))
  }
}

/// Encabezado pequeño de una tarjeta: título y un detalle a la derecha.
struct CardHeader: View {
  let title: String
  var detail: String?
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(IslandTheme.secondary).textCase(.uppercase).tracking(0.6)
      Spacer(minLength: 8)
      if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(IslandTheme.tertiary).lineLimit(1) }
    }
  }
}

// MARK: Contenedor

struct ExpandedIsland: View {
  let state: OverlayState
  let notchW: CGFloat
  let notchH: CGFloat
  @Namespace private var tabs

  var body: some View {
    VStack(spacing: 0) {
      ShoulderRow(notchW: notchW, notchH: notchH) {
        Text(state.page.title)
          .font(.system(size: 13, weight: .semibold))
          .padding(.leading, 6)
          .id(state.page)
          .transition(.blurReplace)
      } trailing: {
        HStack(spacing: 2) {
          ForEach(IslandPage.allCases) { p in
            Button {
              withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { state.page = p }
            } label: {
              Image(systemName: p.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 30, height: 24)
                .foregroundStyle(state.page == p ? .black : .white.opacity(0.55))
                .background {
                  if state.page == p { Capsule().fill(.white).matchedGeometryEffect(id: "tab", in: tabs) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(p.title)
          }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .padding(.trailing, 2)
      }
      ZStack {
        switch state.page {
        case .music: MusicPage(state: state).transition(.blurReplace)
        case .agents: AgentsPage(state: state).transition(.blurReplace)
        case .controls: ControlsPage(state: state).transition(.blurReplace)
        case .shelf: ShelfAndClipboardPage(state: state).transition(.blurReplace)
        case .tools: ToolsPage(state: state).transition(.blurReplace)
        }
      }
      .padding(.horizontal, 18)
      .padding(.top, 12)
      .padding(.bottom, 18)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
}

// MARK: Música

struct MusicPage: View {
  let state: OverlayState
  var body: some View {
    if let music = state.music, let np = music.current {
      HStack(alignment: .center, spacing: 20) {
        ZStack {
          if let art = music.artwork {
            Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
              .frame(width: 118, height: 118).blur(radius: 30).opacity(0.65).scaleEffect(1.08)
          }
          ArtworkThumb(image: music.artwork, size: 118, radius: 20)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        }
        VStack(alignment: .leading, spacing: 0) {
          Text(np.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
          Text(np.artist).font(.system(size: 13)).foregroundStyle(IslandTheme.secondary).lineLimit(1).padding(.top, 2)
          if let bundle = np.appBundleID {
            HStack(spacing: 5) {
              Image(nsImage: AppIcons.icon(bundle)).resizable().frame(width: 12, height: 12)
              Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent ?? "")
                .font(.system(size: 10.5)).foregroundStyle(IslandTheme.tertiary)
            }
            .padding(.top, 6)
          }
          Spacer(minLength: 10)
          TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = np.position(at: ctx.date)
            VStack(spacing: 5) {
              GeometryReader { g in
                ZStack(alignment: .leading) {
                  Capsule().fill(Color.white.opacity(0.16))
                  Capsule().fill(Color.white).frame(width: np.duration > 0 ? g.size.width * CGFloat(min(1, pos / np.duration)) : 0)
                }
              }
              .frame(height: 4)
              HStack {
                Text(MeetingClock.text(pos))
                Spacer()
                Text("-" + MeetingClock.text(max(0, np.duration - pos)))
              }
              .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
              .foregroundStyle(IslandTheme.tertiary)
            }
          }
          .frame(height: 22)
          HStack(spacing: 0) {
            ModeButton(symbol: "shuffle", on: music.shuffling) { music.toggleShuffle() }
            Spacer(minLength: 0)
            MediaButton(symbol: "backward.fill", size: 16) { music.previous() }
            Spacer(minLength: 0)
            MediaButton(symbol: np.playing ? "pause.fill" : "play.fill", size: 20, prominent: true) { music.togglePlayPause() }
            Spacer(minLength: 0)
            MediaButton(symbol: "forward.fill", size: 16) { music.next() }
            Spacer(minLength: 0)
            ModeButton(symbol: "repeat", on: music.repeating) { music.toggleRepeat() }
          }
          .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
      }
      .onAppear { music.refreshModes() }
      .onChange(of: np.title) { music.refreshModes() }
    } else {
      EmptyPage(symbol: "music.note", title: "No suena nada", detail: "Pon música en Spotify, Música o el navegador y aparecerá aquí.")
    }
  }
}

/// Aleatorio o repetir: el ícono se ilumina cuando está activo (con un punto debajo, como en Música).
struct ModeButton: View {
  let symbol: String
  let on: Bool?
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
          .foregroundStyle(on == true ? .white : .white.opacity(0.45))
        Circle().fill(on == true ? Color.white : .clear).frame(width: 3.5, height: 3.5)
      }
      .frame(width: 34, height: 34)
      .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
  }
}

struct MediaButton: View {
  let symbol: String
  var size: CGFloat
  var prominent = false
  let action: () -> Void
  @State private var hover = false
  @State private var pressed = false
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(prominent ? .black : .white)
        .frame(width: prominent ? 44 : 34, height: prominent ? 44 : 34)
        .background(Circle().fill(prominent ? Color.white.opacity(hover ? 1 : 0.92) : Color.white.opacity(hover ? 0.1 : 0)))
        .contentShape(Circle())
        .scaleEffect(pressed ? 0.86 : 1)
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .simultaneousGesture(DragGesture(minimumDistance: 0)
      .onChanged { _ in withAnimation(.spring(response: 0.2)) { pressed = true } }
      .onEnded { _ in withAnimation(.spring(response: 0.3)) { pressed = false } })
  }
}

struct EmptyPage: View {
  let symbol: String
  let title: String
  let detail: String
  var body: some View {
    IslandCard {
      VStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(IslandTheme.tertiary)
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(detail).font(.system(size: 11.5)).foregroundStyle(IslandTheme.secondary).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// MARK: Agentes

struct AgentsPage: View {
  let state: OverlayState
  var body: some View {
    let claude = state.claude
    HStack(alignment: .top, spacing: IslandTheme.gap) {
      IslandCard {
        VStack(alignment: .leading, spacing: 10) {
          let rows = sessions(claude)
          CardHeader(title: "Sesiones de Claude Code", detail: summary(claude))
          if claude?.connected != true {
            Text("Conecta Claude Code en Faro → IA para ver a tus agentes trabajar.").font(.system(size: 11.5)).foregroundStyle(IslandTheme.secondary)
          } else if rows.isEmpty {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
              AgentOrb(size: 18, idle: true)
              Text("Ningún agente trabajando").font(.system(size: 12.5, weight: .medium)).foregroundStyle(IslandTheme.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
          } else {
            ScrollView(showsIndicators: false) {
              VStack(spacing: 6) {
                ForEach(rows, id: \.id) { AgentRow(id: $0.id, session: $0.session) }
              }
            }
          }
        }
      }
      IslandCard {
        VStack(alignment: .leading, spacing: 10) {
          CardHeader(title: "Límites", detail: claude?.limits.map { "hace " + $0.fetchedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)).replacingOccurrences(of: "hace ", with: "") })
          HStack(spacing: 14) {
            RingGauge(title: "5 horas", window: claude?.limits?.fiveHour)
            RingGauge(title: "Semana", window: claude?.limits?.sevenDay)
          }
          .frame(maxWidth: .infinity)
          Spacer(minLength: 0)
          HStack(alignment: .firstTextBaseline) {
            Text("Por API hoy").font(.system(size: 10.5)).foregroundStyle(IslandTheme.tertiary)
            Spacer()
            Text(money(claude?.costToday ?? 0)).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
          }
        }
      }
      .frame(width: 214)
    }
  }

  typealias Row = (id: String, session: ClaudeActivityBoard.Session)

  /// Las que trabajan o esperan, y las que terminaron en la última hora.
  func sessions(_ claude: ClaudeMonitor?) -> [Row] {
    let all = (claude?.board.sessions ?? [:]).map { (id: $0.key, session: $0.value) }
    let recent = Date().addingTimeInterval(-3600)
    func rank(_ s: ClaudeActivityBoard.Session) -> Int { s.state == .waiting ? 0 : (s.state == .working ? 1 : 2) }
    return all.filter { $0.session.state != .idle || $0.session.lastEvent > recent }
      .sorted { (rank($0.session), $1.session.lastEvent) < (rank($1.session), $0.session.lastEvent) }
  }

  func summary(_ claude: ClaudeMonitor?) -> String? {
    let w = claude?.board.workingCount ?? 0, q = claude?.board.waitingCount ?? 0
    if w == 0 && q == 0 { return nil }
    return [w > 0 ? "\(w) trabajando" : nil, q > 0 ? "\(q) te espera\(q > 1 ? "n" : "")" : nil].compactMap { $0 }.joined(separator: " · ")
  }
}

struct AgentRow: View {
  let id: String
  let session: ClaudeActivityBoard.Session
  var body: some View {
    HStack(spacing: 10) {
      Group {
        switch session.state {
        case .working: AgentOrb(size: 16)
        case .waiting: ClaudeWaiting(size: 12)
        case .idle: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(IslandTheme.tertiary)
        }
      }
      .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(session.project).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        Text(status).font(.system(size: 10.5)).foregroundStyle(session.state == .waiting ? Color.orange : IslandTheme.secondary).lineLimit(1)
      }
      Spacer(minLength: 6)
      if session.state == .working, let since = session.workingSince {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
          Text(MeetingClock.text(ctx.date.timeIntervalSince(since)))
            .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
        }
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(session.state == .idle ? 0.025 : 0.05)))
  }

  var status: String {
    switch session.state {
    case .working: return "Trabajando"
    case .waiting: return "Te espera para seguir"
    case .idle: return "Terminó " + session.lastEvent.formatted(.relative(presentation: .named))
    }
  }
}

struct RingGauge: View {
  let title: String
  let window: PlanLimits.Window?
  var body: some View {
    let used = window?.percent ?? 0
    let color: Color = used >= 90 ? .red : (used >= 70 ? .orange : IslandTheme.agent)
    VStack(spacing: 6) {
      ZStack {
        Circle().stroke(Color.white.opacity(0.09), lineWidth: 6)
        Circle()
          .trim(from: 0, to: CGFloat(min(100, used) / 100))
          .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * min(100, used) / 100 + 1)),
                  style: StrokeStyle(lineWidth: 6, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.spring(response: 0.8, dampingFraction: 0.8), value: used)
        Text(window == nil ? "–" : "\(Int(used.rounded()))%")
          .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
      }
      .frame(width: 66, height: 66)
      Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(IslandTheme.secondary)
    }
  }
}

// MARK: Bandeja y portapapeles

struct ShelfAndClipboardPage: View {
  let state: OverlayState
  @Namespace private var seg
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 2) {
        ForEach(OverlayState.ShelfTab.allCases, id: \.self) { t in
          Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.shelfTab = t }
          } label: {
            Text(t.title).font(.system(size: 11, weight: .semibold))
              .padding(.horizontal, 12).frame(height: 24)
              .foregroundStyle(state.shelfTab == t ? .black : .white.opacity(0.6))
              .background { if state.shelfTab == t { Capsule().fill(.white).matchedGeometryEffect(id: "seg", in: seg) } }
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(2)
      .background(Capsule().fill(Color.white.opacity(0.07)))
      Group {
        switch state.shelfTab {
        case .files: ShelfPage(state: state)
        case .clipboard: ClipboardPage(state: state)
        }
      }
      .transition(.blurReplace)
    }
  }
}

// MARK: Herramientas

struct ToolsPage: View {
  let state: OverlayState
  var body: some View {
    let app = state.app
    let recording = app?.meetings.isRecording == true
    let paused = app?.settings.paused == true
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
      ToolButton(symbol: "keyboard", tint: .blue, title: "Limpiar teclado", subtitle: "Bloquea las teclas 60 s") {
        app?.overlay.collapse()
        app?.keyboard.start()
      }
      ToolButton(symbol: "shippingbox.fill", tint: .brown, title: "Homebrew", subtitle: brewSubtitle(app?.brew)) {
        if let brew = app?.brew, !brew.outdated.isEmpty { brew.upgrade(brew.outdated) } else { app?.brew.check() }
      }
      ToolButton(symbol: recording ? "stop.fill" : "record.circle", tint: .red,
                 title: recording ? "Terminar reunión" : "Grabar reunión", subtitle: "Transcribe y resume") {
        app?.overlay.collapse()
        app?.toggleMeetingFromIsland()
      }
      if recording, let meetings = app?.meetings {
        ToolButton(symbol: meetings.isPaused ? "play.fill" : "pause.fill", tint: .orange,
                   title: meetings.isPaused ? "Reanudar" : "Pausar grabación",
                   subtitle: meetings.isPaused ? "Sigue grabando" : "El micrófono se apaga") {
          meetings.togglePause()
        }
      } else {
        ToolButton(symbol: "chart.bar.fill", tint: IslandTheme.agent, title: "Uso de IA", subtitle: "Detalle por modelo") {
          app?.overlay.collapse()
          app?.model.requestedPane = .ai
          app?.openWindow()
        }
      }
      ToolButton(symbol: paused ? "mic.slash.fill" : "mic.fill", tint: Theme.violet,
                 title: paused ? "Reanudar dictado" : "Pausar dictado", subtitle: "Tecla fn") {
        app?.settings.paused.toggle()
        app?.updateMenu()
      }
      ToolButton(symbol: "macwindow", tint: .clear, title: "Abrir Faro", subtitle: "Historial y ajustes", image: NSApp.applicationIconImage) {
        app?.overlay.collapse()
        app?.openWindow()
      }
      if let quick = app?.quick {
        AwakeButton(quick: quick)
        TimerButton(quick: quick)
        ToolButton(symbol: "eyedropper", tint: .pink, title: "Color", subtitle: "Copia el hex") {
          app?.overlay.collapse()
          quick.pickColor()
        }
      }
    }
  }

  func brewSubtitle(_ brew: BrewService?) -> String {
    guard let brew, brew.available else { return "No instalado" }
    if !brew.upgrading.isEmpty { return "Actualizando…" }
    if brew.checking { return "Revisando…" }
    return brew.outdated.isEmpty ? "Todo al día" : "\(brew.outdated.count) para actualizar"
  }
}

struct ToolButton: View {
  let symbol: String
  var tint: Color
  let title: String
  let subtitle: String
  var image: NSImage?
  let action: () -> Void
  @State private var hover = false

  init(symbol: String, tint: Color, title: String, subtitle: String, image: NSImage? = nil, action: @escaping () -> Void) {
    self.symbol = symbol
    self.tint = tint
    self.title = title
    self.subtitle = subtitle
    self.image = image
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        ZStack {
          if let image {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
          } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.9))
            Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
          }
        }
        .frame(width: 30, height: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
          Text(subtitle).font(.system(size: 10.5)).foregroundStyle(IslandTheme.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .frame(height: 54)
      .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(hover ? 0.11 : 0.06)))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(IslandTheme.cardStroke, lineWidth: 0.5))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
  }
}

// MARK: Animación de los agentes

/// Agente trabajando: un punto coral que respira y suelta una onda que se abre y se
/// desvanece, cada 1,8 s. En reposo, el punto quieto y tenue.
struct AgentOrb: View {
  var size: CGFloat = 14
  var idle = false
  static let period = 1.8

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: idle)) { tl in
      let phase = idle ? 0 : tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
      let dot = size * 0.5
      // El punto crece hasta el 60 % del ciclo y vuelve; la onda nace con él y se apaga al abrirse.
      let breath = idle ? 0.9 : 0.85 + 0.15 * sin(min(phase / 0.6, 1) * .pi)
      let wave = min(phase / 0.6, 1)
      ZStack {
        if !idle {
          Circle()
            .stroke(IslandTheme.agent.opacity(0.55 * (1 - wave)), lineWidth: 1.5)
            .frame(width: dot + (size - dot) * wave * 1.15, height: dot + (size - dot) * wave * 1.15)
        }
        Circle()
          .fill(IslandTheme.agent.opacity(idle ? 0.35 : 1))
          .frame(width: dot, height: dot)
          .scaleEffect(breath)
      }
      .frame(width: size, height: size)
    }
  }
}
