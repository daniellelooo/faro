import AppKit
import FaroCore
import SwiftUI
import UniformTypeIdentifiers

extension Color {
  /// Naranja de Claude.
  static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// Silueta del notch: hombros que se abren arriba (como el notch real) y esquinas redondeadas abajo.
/// Los radios son animables, así la isla se transforma de forma continua.
struct IslandShape: Shape {
  var topRadius: CGFloat
  var bottomRadius: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(topRadius, bottomRadius) }
    set {
      topRadius = newValue.first
      bottomRadius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let t = topRadius
    let b = min(bottomRadius, (rect.height - t) / 1.2, rect.width / 3)
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
    p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
    p.closeSubpath()
    return p
  }
}

/// La isla de Faro: una sola forma negra que crece desde el notch según lo que pase.
struct IslandView: View {
  let state: OverlayState

  enum Mode: Hashable { case hidden, idle, peek, dictation, hud, notice, activity, expanded }

  struct Spec: Equatable {
    var width: CGFloat
    var height: CGFloat
    var top: CGFloat
    var bottom: CGFloat
  }

  var musicPlaying: Bool { state.music?.current?.playing == true }
  var claudeBusy: Bool { (state.claude?.board.workingCount ?? 0) + (state.claude?.board.waitingCount ?? 0) > 0 }
  var timerRunning: Bool { state.app?.quick.timerRunning == true }
  var hasNotch: Bool { state.notchWidth > 0 }
  var notchW: CGFloat { hasNotch ? state.notchWidth : 180 }
  var notchH: CGFloat { max(state.notchHeight, 26) }

  var mode: Mode {
    if state.expanded { return .expanded }
    if state.dictationActive { return .dictation }
    if state.hud != nil { return .hud }
    if state.liveNotice != nil { return .notice }
    if state.hovering { return .peek }
    if !state.suppressActivities && (musicPlaying || claudeBusy || timerRunning) { return .activity }
    return state.idleVisible ? .idle : .hidden
  }

  func spec(_ m: Mode) -> Spec {
    switch m {
    case .hidden: return Spec(width: notchW, height: notchH, top: 6, bottom: 10)
    case .idle: return Spec(width: notchW + 2 * state.idleShoulder, height: notchH, top: 6, bottom: 11)
    case .hud: return Spec(width: notchW + 150, height: notchH + 24, top: 7, bottom: 16)
    case .peek: return Spec(width: notchW + 110, height: notchH + 16, top: 7, bottom: 14)
    case .activity:
      // Más ancho cuando a la derecha van el contador de agentes y el tiempo.
      let agents = state.claude?.board.workingCount ?? 0
      let shoulder: CGFloat = agents > 1 ? (musicPlaying ? 92 : 80) : (agents == 1 && musicPlaying ? 76 : 66)
      return Spec(width: notchW + 2 * shoulder, height: notchH, top: 6, bottom: 11)
    case .dictation:
      switch state.phase {
      case .notice: return Spec(width: notchW + 230, height: notchH + 40, top: 8, bottom: 20)
      case .meeting: return Spec(width: notchW + 150, height: notchH, top: 6, bottom: 11)
      default: return Spec(width: notchW + 200, height: notchH, top: 6, bottom: 11)
      }
    case .notice: return Spec(width: max(notchW + 190, 400), height: notchH + 66, top: 9, bottom: 24)
    case .expanded:
      // El alto se adapta a cada página (la isla se estira suave al cambiar).
      let h: CGFloat = {
        switch state.page {
        case .music: return 210
        case .agents: return 252
        case .controls:
          // Una fila por el volumen y una por cada pantalla: el alto crece con ellas para que nada quede cortado.
          let rows = CGFloat(1 + (state.app?.displays.displays.count ?? 1))
          return 112 + 57 * rows
        case .shelf: return 236
        case .tools: return 264
        }
      }()
      return Spec(width: OverlayPanel.expandedSize.width, height: h + notchH - 32, top: 12, bottom: 36)
    }
  }

  var body: some View {
    let m = mode
    let s = spec(m)
    let spring = Animation.spring(response: 0.44, dampingFraction: 0.78)
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        IslandBackground(expanded: m == .expanded, shape: IslandShape(topRadius: s.top, bottomRadius: s.bottom), notchH: notchH)
          .frame(width: s.width + 2 * s.top, height: s.height)
          .shadow(color: .black.opacity(m == .expanded ? 0.45 : (m == .hidden ? 0 : 0.25)), radius: m == .expanded ? 24 : 10, y: m == .expanded ? 10 : 4)
        content(m)
          .frame(width: s.width, height: s.height, alignment: .top)
          .clipped()
          .id(m == .expanded ? "expanded" : (m == .dictation ? "dictation-\(phaseKey)" : "\(m)"))
          .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).animation(spring.delay(0.06)),
                                  removal: .opacity.animation(.easeOut(duration: 0.12))))
      }
      .onDrop(of: [.fileURL], delegate: ShelfDropDelegate(state: state))
      .opacity(m == .hidden && !hasNotch ? 0 : 1)
      .animation(spring, value: s)
      .animation(spring, value: m)
      Spacer(minLength: 0)
    }
    .frame(width: OverlayPanel.panelSize.width, height: OverlayPanel.panelSize.height, alignment: .top)
    .foregroundStyle(.white)
  }

  var phaseKey: String {
    switch state.phase {
    case .listening: return "listening"
    case .processing: return "processing"
    case .meeting: return "meeting"
    case .notice: return "notice"
    default: return "other"
    }
  }

  @ViewBuilder func content(_ m: Mode) -> some View {
    switch m {
    case .hidden: Color.clear
    case .hud: HUDIsland(state: state, notchW: notchW, notchH: notchH)
    case .idle, .peek: IdleIsland(state: state, notchW: notchW, notchH: notchH, peek: m == .peek)
    case .dictation: DictationIsland(state: state, notchW: notchW, notchH: notchH)
    case .notice: NoticeIsland(state: state, notchH: notchH)
    case .activity: ActivityIsland(state: state, notchW: notchW, notchH: notchH)
    case .expanded: ExpandedIsland(state: state, notchW: notchW, notchH: notchH)
    }
  }
}

/// Fondo de la isla. Cerrada es negro puro (se funde con el notch). Abierta es cristal oscuro (Liquid Glass en
/// macOS 26): deja ver difuminado lo que hay detrás, con el borde que refracta la luz; arriba se oscurece hasta el
/// negro para seguir unida al notch.
struct IslandBackground: View {
  let expanded: Bool
  let shape: IslandShape
  let notchH: CGFloat
  var body: some View {
    if expanded, #available(macOS 26.0, *) {
      ZStack {
        Color.clear.glassEffect(.regular.tint(Color.black.opacity(0.42)), in: shape)
        shape.fill(LinearGradient(stops: [
          .init(color: .black, location: 0),
          .init(color: .black.opacity(0.85), location: min(0.3, (notchH + 6) / 260)),
          .init(color: .black.opacity(0.25), location: 0.55),
          .init(color: .black.opacity(0.1), location: 1),
        ], startPoint: .top, endPoint: .bottom))
        shape.stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
      }
    } else {
      shape.fill(Color.black)
    }
  }
}

/// Fila a la altura del notch: contenido pegado a los hombros izquierdo y derecho.
struct ShoulderRow<L: View, R: View>: View {
  let notchW: CGFloat
  let notchH: CGFloat
  var inset: CGFloat = 14
  @ViewBuilder var leading: L
  @ViewBuilder var trailing: R
  var body: some View {
    HStack(spacing: 0) {
      leading.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, inset)
      Color.clear.frame(width: notchW)
      trailing.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, inset)
    }
    .frame(height: notchH)
  }
}

// MARK: Dictado y reuniones

struct DictationIsland: View {
  let state: OverlayState
  let notchW: CGFloat
  let notchH: CGFloat
  var body: some View {
    VStack(spacing: 0) {
      ShoulderRow(notchW: notchW, notchH: notchH) {
        switch state.phase {
        case .listening:
          HStack(spacing: 7) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            LevelBars(level: state.level).frame(height: 16)
          }
        case .processing: Spinner()
        case .meeting:
          if state.meetingPaused {
            Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
          } else {
            PulsingDot(color: .red)
          }
        case .notice: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(.orange)
        default: EmptyView()
        }
      } trailing: {
        switch state.phase {
        case .listening: label(state.handsFree ? "Manos libres" : "Escuchando")
        case .processing: label("Procesando")
        case .meeting:
          label(state.meetingPaused ? "En pausa" : MeetingClock.text(state.meetingElapsed)).monospacedDigit()
        default: EmptyView()
        }
      }
      if case .notice(let text) = state.phase {
        Text(text)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 18)
          .frame(maxHeight: .infinity)
      }
    }
  }
  func label(_ t: String) -> some View {
    Text(t).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
  }
}

struct PulsingDot: View {
  var color: Color
  @State private var on = false
  var body: some View {
    Circle().fill(color).frame(width: 8, height: 8)
      .shadow(color: color.opacity(on ? 0.9 : 0.2), radius: on ? 5 : 1)
      .opacity(on ? 1 : 0.55)
      .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
  }
}

// MARK: Actividades con la isla cerrada

struct ActivityIsland: View {
  let state: OverlayState
  let notchW: CGFloat
  let notchH: CGFloat
  var body: some View {
    let playing = state.music?.current?.playing == true
    let board = state.claude?.board
    let waiting = (board?.waitingCount ?? 0) > 0
    let workingCount = board?.workingCount ?? 0
    let longest = board?.longestWorking
    let quick = state.app?.quick
    if let quick, quick.timerRunning, !waiting {
      ShoulderRow(notchW: notchW, notchH: notchH) {
        TimerRing(quick: quick)
      } trailing: {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
          Text(QuickTools.clock(quick.timerRemaining(at: ctx.date)))
            .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.mint)
        }
      }
    } else {
      // Izquierda: la música (si suena) o el estado de los agentes. Derecha: los agentes (si hay) o el ecualizador.
      ShoulderRow(notchW: notchW, notchH: notchH) {
        if playing {
          ArtworkThumb(image: state.music?.artwork, size: 20, radius: 5)
        } else if waiting {
          ClaudeWaiting(size: 11)
        } else if workingCount > 0 {
          AgentOrb(size: 14)
        }
      } trailing: {
        if waiting {
          HStack(spacing: 5) {
            if playing { ClaudeWaiting(size: 10) }
            Text("Te espera").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
          }
        } else if let longest {
          TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 6) {
              if playing { AgentOrb(size: 12) }
              if workingCount > 1 {
                Text("\(workingCount)").font(.system(size: 10, weight: .bold, design: .rounded))
                  .frame(minWidth: 15, minHeight: 15)
                  .background(Circle().fill(IslandTheme.agent.opacity(0.25)))
                  .foregroundStyle(IslandTheme.agent)
              }
              Text(MeetingClock.text(ctx.date.timeIntervalSince(longest.workingSince ?? ctx.date)))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            }
          }
        } else if playing {
          MusicBars(playing: true)
        }
      }
    }
  }
}

/// Anillo que se vacía con el temporizador.
struct TimerRing: View {
  let quick: QuickTools
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let total = max(quick.timerDuration, 1)
      let left = quick.timerRemaining(at: ctx.date) / total
      ZStack {
        Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
        Circle().trim(from: 0, to: CGFloat(left))
          .stroke(Color.mint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.linear(duration: 1), value: left)
      }
      .frame(width: 13, height: 13)
    }
  }
}

/// Volumen o brillo: ícono y porcentaje a los lados del notch y una barra debajo.
struct HUDIsland: View {
  let state: OverlayState
  let notchW: CGFloat
  let notchH: CGFloat
  var body: some View {
    let hud = state.hud ?? LevelHUD(kind: .volume, value: 0, label: "")
    let shown: Float = hud.muted ? 0 : hud.value
    VStack(spacing: 0) {
      ShoulderRow(notchW: notchW, notchH: notchH) {
        Image(systemName: hud.symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 18)
      } trailing: {
        Text(hud.muted ? "Silencio" : "\(Int((hud.value * 100).rounded()))%")
          .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(.white.opacity(0.9))
          .contentTransition(.numericText())
      }
      HStack(spacing: 8) {
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.16))
            Capsule().fill(Color.white)
              .frame(width: max(5, geo.size.width * CGFloat(shown)))
          }
        }
        .frame(height: 5)
        Text(hud.label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
          .frame(maxWidth: 110, alignment: .trailing)
      }
      .padding(.horizontal, 18)
      .frame(height: 22)
    }
  }
}

/// En reposo: la isla asoma por los lados del notch con tu límite de 5 horas y lo que llevas hoy.
struct IdleIsland: View {
  let state: OverlayState
  let notchW: CGFloat
  let notchH: CGFloat
  let peek: Bool
  var body: some View {
    VStack(spacing: 0) {
      ShoulderRow(notchW: notchW, notchH: notchH, inset: 11) {
        HStack(spacing: 5) {
          IdleItemView(item: state.idleLeft, state: state)
          if state.app?.quick.isAwake == true {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.7))
              .help("Mac despierto")
          }
        }
      } trailing: {
        IdleItemView(item: state.idleRight, state: state)
      }
      if peek {
        Text("Abrir Faro").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
          .frame(maxWidth: .infinity)
      }
    }
  }
}

struct MiniRing: View {
  let percent: Double
  static func color(_ p: Double) -> Color { p >= 90 ? .red : (p >= 70 ? .orange : .claude) }
  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
      Circle().trim(from: 0, to: CGFloat(min(100, percent) / 100))
        .stroke(Self.color(percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: 13, height: 13)
  }
}

struct ArtworkThumb: View {
  let image: NSImage?
  var size: CGFloat
  var radius: CGFloat
  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        ZStack {
          Color.white.opacity(0.1)
          Image(systemName: "music.note").font(.system(size: size * 0.45))
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}

// MARK: Avisos

struct NoticeIsland: View {
  let state: OverlayState
  let notchH: CGFloat
  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: notchH)
      HStack(spacing: 12) {
        switch state.liveNotice {
        case .track(let title, let artist):
          ArtworkThumb(image: state.music?.artwork, size: 42, radius: 9)
            .shadow(color: (state.music?.accent ?? .clear).opacity(0.6), radius: 8)
          texts(title, artist)
          MusicBars(playing: true, color: state.music?.accent ?? .white)
        case .claude(.finished(let project, let seconds)):
          DrawnCheck()
          texts("Claude terminó", "\(project) · \(MeetingClock.text(Double(seconds)))")
        case .claude(.needsYou(let project)):
          ZStack { Circle().fill(Color.orange.opacity(0.18)); ClaudeWaiting(size: 16) }.frame(width: 40, height: 40)
          texts("Claude te necesita", project)
        case .text(let text, let symbol):
          badge(symbol, Theme.violet)
          texts(text, nil)
        case nil:
          EmptyView()
        }
      }
      .padding(.horizontal, 18)
      .frame(maxHeight: .infinity)
    }
  }

  func texts(_ title: String, _ subtitle: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
      if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func badge(_ symbol: String, _ color: Color) -> some View {
    ZStack {
      Circle().fill(color.opacity(0.22))
      Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(color)
    }
    .frame(width: 40, height: 40)
  }
}

