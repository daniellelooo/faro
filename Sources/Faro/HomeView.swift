import AppKit
import FaroCore
import SwiftUI

/// Inicio: cómo vas con Claude, en qué proyectos estás trabajando y lo que pasa en el Mac.
struct HomeView: View {
  let app: AppDelegate
  @Bindable var settings: AppSettings
  @Bindable var model: AppModel
  @Binding var pane: Pane?

  var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    let base = hour < 12 ? "Buenos días" : (hour < 19 ? "Buenas tardes" : "Buenas noches")
    return first.isEmpty ? base : "\(base), \(first)"
  }

  var dateLine: String {
    Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "es_CO"))).capitalizedFirst
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PaneHeader(title: greeting, subtitle: dateLine)

        AttentionCard(items: attention)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
          ShortcutTile(symbol: "sparkles", tint: Color.claude, title: "Claude", value: claudeValue) { pane = .ai }
          ShortcutTile(symbol: "folder.fill", tint: .teal, title: "Proyectos", value: projectsValue) { pane = .ai }
          MusicTile(music: app.music)
          ShortcutTile(symbol: "tray.full.fill", tint: .mint, title: "Bandeja",
            value: app.shelf.items.isEmpty ? "Arrastra archivos al notch" : (app.shelf.items.count == 1 ? "1 archivo" : "\(app.shelf.items.count) archivos")) {
            app.overlay.state.shelfTab = .files
            openIsland(.shelf)
          }
          ShortcutTile(symbol: "doc.on.clipboard.fill", tint: .indigo, title: "Portapapeles",
            value: clipValue) { app.overlay.state.shelfTab = .clipboard; openIsland(.shelf) }
          ShortcutTile(symbol: "shippingbox.fill", tint: .brown, title: "Homebrew",
            value: app.brew.outdated.isEmpty ? "Al día" : "\(app.brew.outdated.count) por actualizar") { pane = .tools }
          ShortcutTile(symbol: app.quick.timerRunning ? "timer" : "cup.and.saucer.fill", tint: .yellow, title: "Rápidas", value: quickValue) { pane = .tools }
          ShortcutTile(symbol: "waveform", tint: Theme.violet, title: "Dictado", value: dictationValue) { pane = .history }
          ShortcutTile(symbol: "person.3.fill", tint: Theme.coral, title: "Reuniones", value: meetingsValue) { pane = .meetings }
        }
      }
      .padding(28)
      .frame(maxWidth: 880, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  func openIsland(_ page: IslandPage) {
    app.overlay.state.page = page
    app.overlay.expand()
  }

  var claudeValue: String {
    var parts: [String] = []
    if let f = app.claude.limits?.fiveHour { parts.append("\(Int(f.percent.rounded())) % de 5 h") }
    if let w = app.claude.limits?.sevenDay { parts.append("semana \(Int(w.percent.rounded())) %") }
    if app.claude.report != nil { parts.append(money(app.claude.costToday) + " hoy") }
    return parts.isEmpty ? "Límites y gasto" : parts.joined(separator: " · ")
  }

  var projectsValue: String {
    let today = Calendar.current.startOfDay(for: Date())
    let active = app.claude.projects.projects.filter { ($0.lastActivity ?? .distantPast) >= today }
    if active.isEmpty { return "Sin actividad hoy" }
    return (active.count == 1 ? "1 activo hoy: " : "\(active.count) activos hoy: ") + active.prefix(3).map(\.name).joined(separator: ", ")
  }

  var clipValue: String {
    let n = app.clipboard.history.entries.count
    return n == 0 ? "Lo que copies aparece aquí" : (n == 1 ? "1 texto copiado" : "\(n) textos copiados")
  }

  var quickValue: String {
    if app.quick.timerRunning { return "Temporizador corriendo" }
    if app.quick.isAwake { return "Mac despierto" }
    return "Despierto, temporizador y color"
  }

  var attention: [AttentionItem] { app.attentionItems() }


  var dictationValue: String {
    let _ = model.historyVersion
    let words = HistoryStats(entries: app.history.entries).wordsThisWeek
    return words == 0 ? "Mantén fn y habla" : "\(words) palabras esta semana"
  }

  var meetingsValue: String {
    if app.meetings.isRecording { return "Grabando ahora" }
    let n = app.meetings.meetings.count
    return n == 0 ? "Ninguna grabada" : (n == 1 ? "1 grabada" : "\(n) grabadas")
  }
}

extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Anillo de porcentaje para fondos claros u oscuros.
struct PercentRing: View {
  let percent: Double?
  var size: CGFloat = 76
  var line: CGFloat = 8
  var body: some View {
    let used = percent ?? 0
    let color: Color = used >= 90 ? .red : (used >= 70 ? .orange : Color.claude)
    ZStack {
      Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
      Circle()
        .trim(from: 0, to: CGFloat(min(100, used) / 100))
        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: used)
      HStack(alignment: .firstTextBaseline, spacing: 1) {
        Text(percent == nil ? "–" : "\(Int(used.rounded()))").font(.system(size: size * 0.29, weight: .bold, design: .rounded)).monospacedDigit()
        if percent != nil { Text("%").font(.system(size: size * 0.13, weight: .semibold)).foregroundStyle(.secondary) }
      }
    }
    .frame(width: size, height: size)
  }
}

struct LimitsCard: View {
  let claude: ClaudeMonitor
  @Binding var pane: Pane?
  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Límites de Claude", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
          Spacer()
          if let l = claude.limits {
            Text(l.fetchedAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
          }
        }
        if let l = claude.limits {
          HStack(spacing: 26) {
            gauge("5 horas", l.fiveHour)
            gauge("Semana", l.sevenDay)
            ForEach(l.models.prefix(1)) { gauge($0.title, $0) }
          }
          .frame(maxWidth: .infinity)
        } else {
          VStack(alignment: .leading, spacing: 10) {
            Text(claude.hasLimitsToken ? (claude.limitsProblem ?? "Consultando tu cuenta…")
              : "Faro todavía no puede leer tus límites. Se activa una vez, en un minuto.")
              .foregroundStyle(.secondary)
            if !claude.hasLimitsToken {
              Button("Activar límites") { pane = .ai }.buttonStyle(.borderedProminent)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
  }

  func gauge(_ title: String, _ w: PlanLimits.Window?) -> some View {
    VStack(spacing: 6) {
      PercentRing(percent: w?.percent)
      Text(title).font(.callout.weight(.semibold))
      Text(w?.resetsAt.map { "reinicia " + $0.formatted(.relative(presentation: .named)) } ?? " ")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct SpendCard: View {
  let claude: ClaudeMonitor
  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 10) {
        Label("Si pagaras por API", systemImage: "dollarsign.circle").font(.headline)
        if claude.report == nil {
          HStack { ProgressView().controlSize(.small); Text("Calculando…").foregroundStyle(.secondary) }
        } else {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(money(claude.costToday)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
            Text("hoy").foregroundStyle(.secondary)
          }
          DayBars(values: weekValues, highlight: Color.claude, base: Color.primary.opacity(0.14)).frame(height: 44)
          HStack {
            VStack(alignment: .leading) {
              Text(money(claude.costWeek)).font(.headline).monospacedDigit()
              Text("7 días").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
              Text(money(claude.costMonth)).font(.headline).monospacedDigit()
              Text("este mes").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .frame(width: 270)
  }

  var weekValues: [Double] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    return (0..<7).reversed().map { claude.report?.byDay[cal.date(byAdding: .day, value: -$0, to: today)!] ?? 0 }
  }
}

func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2))) }

/// Barras de los últimos días; la última (hoy) resaltada.
struct DayBars: View {
  let values: [Double]
  var highlight: Color
  var base: Color
  var body: some View {
    let maxV = max(values.max() ?? 1, 0.01)
    GeometryReader { geo in
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(Array(values.enumerated()), id: \.offset) { i, v in
          RoundedRectangle(cornerRadius: 2.5)
            .fill(i == values.count - 1 ? highlight : base)
            .frame(height: max(3, geo.size.height * CGFloat(v / maxV)))
        }
      }
      .frame(maxHeight: .infinity, alignment: .bottom)
    }
  }
}

struct ProjectRow: View {
  let project: ProjectInfo
  let board: ClaudeActivityBoard
  @State private var hover = false

  var claudeState: ClaudeActivityBoard.State? {
    let mine = board.sessions.values.filter { s in
      guard let c = s.cwd else { return false }
      return c == project.root || c.hasPrefix(project.root + "/")
    }
    if mine.contains(where: { $0.state == .waiting }) { return .waiting }
    if mine.contains(where: { $0.state == .working }) { return .working }
    return nil
  }

  var body: some View {
    HStack(spacing: 14) {
      badge
      VStack(alignment: .leading, spacing: 4) {
        titleLine
        HStack(spacing: 10) {
          gitChips
          healthChips
        }
        .fixedSize()
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 12)
      DayBars(values: project.week, highlight: color, base: Color.primary.opacity(0.12)).frame(width: 70, height: 26)
      totals
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hover ? color.opacity(0.5) : Theme.subtleBorder))
    .onHover { hover = $0 }
    .contentShape(Rectangle())
    .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: project.root)) }
    .contextMenu {
      Button("Abrir en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.root)) }
      Button("Abrir en Terminal") {
        NSWorkspace.shared.open([URL(fileURLWithPath: project.root)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
          configuration: NSWorkspace.OpenConfiguration())
      }
    }
    .help(project.root)
  }

  var badge: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.16))
      Text(String(project.name.prefix(1)).uppercased()).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(color)
    }
    .frame(width: 38, height: 38)
  }

  @ViewBuilder var gitChips: some View {
    if let g = project.git {
      Label(g.branch, systemImage: "arrow.triangle.branch")
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
      if g.changes > 0 {
        Text(g.changes == 1 ? "1 cambio sin commit" : "\(g.changes) cambios sin commit")
          .font(.caption.weight(.medium)).foregroundStyle(.orange)
      }
    }
  }

  @ViewBuilder var claudeChip: some View {
    switch claudeState {
    case .working?: ProjectChip(text: "Claude trabajando", color: Color.claude, spinning: true)
    case .waiting?: ProjectChip(text: "Claude te espera", color: .orange, spinning: false)
    default: EmptyView()
    }
  }

  var titleLine: some View {
    HStack(spacing: 8) {
      Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
      claudeChip
    }
  }

  @ViewBuilder var healthChips: some View {
    if let h = project.health {
      if let ci = h.ci { HealthChip(label: "CI", state: ci, url: h.ciURL ?? "https://github.com/\(h.repo)/actions") }
      if let d = h.deploy { HealthChip(label: "Despliegue", state: d, url: h.deployURL) }
      if !h.pullRequests.isEmpty {
        let failing = h.pullRequests.contains { $0.checks == .failure }
        Button {
          NSWorkspace.shared.open(URL(string: "https://github.com/\(h.repo)/pulls")!)
        } label: {
          Label(h.pullRequests.count == 1 ? "1 PR" : "\(h.pullRequests.count) PR", systemImage: "arrow.triangle.pull")
            .font(.caption.weight(.medium))
            .foregroundStyle(failing ? .red : .secondary)
        }
        .buttonStyle(.plain)
        .help(h.pullRequests.map { "#\($0.number) \($0.title)" + ($0.checks == .failure ? " (checks en rojo)" : "") }.joined(separator: "\n"))
      }
    }
  }

  var totals: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(money(project.costWeek)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
      Text(project.sessions == 1 ? "1 sesión" : "\(project.sessions) sesiones").font(.caption).foregroundStyle(.secondary)
    }
    .frame(width: 84, alignment: .trailing)
  }

  var detail: String {
    var parts: [String] = []
    if let c = project.git?.lastCommit {
      var t = "“\(c)”"
      if let d = project.git?.lastCommitDate { t += " " + d.formatted(.relative(presentation: .named)) }
      parts.append(t)
    }
    if let a = project.lastActivity { parts.append("Claude " + a.formatted(.relative(presentation: .named))) }
    return parts.joined(separator: " · ")
  }

  /// Color estable por proyecto.
  var color: Color {
    let palette: [Color] = [Theme.violet, Theme.coral, .teal, .blue, .pink, .indigo, .green, .orange]
    let h = project.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return palette[h % palette.count]
  }
}

struct ProjectChip: View {
  let text: String
  let color: Color
  let spinning: Bool
  var body: some View {
    HStack(spacing: 4) {
      if spinning { Spinner(color: color).scaleEffect(0.6).frame(width: 10, height: 10) } else { Circle().fill(color).frame(width: 6, height: 6) }
      Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
    }
    .padding(.horizontal, 7).padding(.vertical, 2)
    .background(Capsule().fill(color.opacity(0.12)))
  }
}

struct MusicTile: View {
  let music: NowPlayingService
  var body: some View {
    Card(padding: 14) {
      HStack(spacing: 10) {
        Group {
          if let art = music.artwork {
            Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
          } else {
            ZStack { Color.pink.opacity(0.15); Image(systemName: "music.note").foregroundStyle(.pink) }
          }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(music.current?.title ?? "Música").font(.callout.weight(.semibold)).lineLimit(1)
          Text(music.current.map { $0.playing ? $0.artist : "En pausa · \($0.artist)" } ?? "Nada sonando")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        if music.current != nil {
          Button { music.send("toggle") } label: {
            Image(systemName: music.current?.playing == true ? "pause.fill" : "play.fill")
          }
          .buttonStyle(.borderless)
        }
      }
    }
  }
}

struct ShortcutTile: View {
  let symbol: String
  let tint: Color
  let title: String
  let value: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Card(padding: 14) {
        HStack(spacing: 10) {
          ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.15))
            Image(systemName: symbol).foregroundStyle(tint)
          }
          .frame(width: 38, height: 38)
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
      }
    }
    .buttonStyle(.plain)
  }
}

struct StatTile: View {
  let value: String
  let label: String
  let symbol: String
  var body: some View {
    Card(padding: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: symbol).foregroundStyle(Theme.violet)
        Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Estado de CI o despliegue: verde, amarillo (corriendo) o rojo. Clic abre el detalle.
struct HealthChip: View {
  let label: String
  let state: RepoHealth.State
  let url: String?
  var color: Color {
    switch state {
    case .success: return .green
    case .pending: return .yellow
    case .failure: return .red
    }
  }
  var symbol: String {
    switch state {
    case .success: return "checkmark.circle.fill"
    case .pending: return "clock.fill"
    case .failure: return "xmark.octagon.fill"
    }
  }
  var body: some View {
    Button {
      if let url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color)
        Text(label).font(.caption.weight(.medium)).foregroundStyle(state == .failure ? .red : .secondary)
      }
    }
    .buttonStyle(.plain)
    .help(state == .success ? "\(label): todo en verde" : (state == .pending ? "\(label): corriendo" : "\(label): falló"))
  }
}

struct AttentionItem: Identifiable {
  var id: String { text }
  let symbol: String
  let color: Color
  let text: String
  let url: String?
}

/// Lo pendiente, arriba del resumen. Si no hay nada, una sola línea tranquila.
struct AttentionCard: View {
  let items: [AttentionItem]
  var body: some View {
    Card(padding: 16) {
      if items.isEmpty {
        HStack(spacing: 10) {
          Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
          Text("Todo en orden: nada te está esperando.").foregroundStyle(.secondary)
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(items.prefix(5)) { item in
            HStack(spacing: 10) {
              Image(systemName: item.symbol).foregroundStyle(item.color).frame(width: 18)
              Text(item.text)
              Spacer()
              if let url = item.url, let u = URL(string: url) {
                Button("Ver") { NSWorkspace.shared.open(u) }.buttonStyle(.link)
              }
            }
          }
        }
      }
    }
  }
}

/// Lista de proyectos con Claude Code (va en la página IA).
struct ProjectsSection: View {
  let claude: ClaudeMonitor
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Tus proyectos").font(.title3.weight(.semibold))
        Text("últimos 14 días con Claude Code").font(.callout).foregroundStyle(.secondary)
        Spacer()
      }
      let projects = claude.projects.projects
      if projects.isEmpty {
        Card {
          HStack(spacing: 10) {
            if claude.report == nil { ProgressView().controlSize(.small) }
            Text(claude.report == nil ? "Leyendo tu historial de Claude Code…" : "Todavía no hay sesiones de Claude Code recientes.")
              .foregroundStyle(.secondary)
          }
        }
      } else {
        VStack(spacing: 8) {
          ForEach(projects) { ProjectRow(project: $0, board: claude.board) }
        }
      }
    }
  }
}
