import FaroCore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
  case home, time, meetings, voice, ai, tools, settings
  var id: String { rawValue }
  var title: String {
    switch self {
    case .home: return "Hoy"
    case .time: return "Tiempo"
    case .meetings: return "Reuniones"
    case .voice: return "Voz"
    case .ai: return "Claude"
    case .tools: return "Mac"
    case .settings: return "Ajustes"
    }
  }
  var symbol: String {
    switch self {
    case .home: return "sun.max.fill"
    case .time: return "chart.bar.xaxis"
    case .meetings: return "person.2.fill"
    case .voice: return "waveform"
    case .ai: return "sparkles"
    case .tools: return "macbook"
    case .settings: return "gearshape.fill"
    }
  }
  var tint: Color {
    switch self {
    case .home: return .orange
    case .time: return .blue
    case .meetings: return Theme.coral
    case .voice: return Theme.violet
    case .ai: return Color.claude
    case .tools: return .teal
    case .settings: return .gray
    }
  }
}

struct MainWindowView: View {
  let app: AppDelegate
  @Bindable var settings: AppSettings
  @Bindable var model: AppModel
  @State private var pane: Pane? = .home

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 30, height: 30)
          VStack(alignment: .leading, spacing: 1) {
            Text("Faro").font(.system(size: 14, weight: .semibold))
            EngineBadge(status: model.engine, paused: settings.paused)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 10)
        List(selection: $pane) {
          Section {
            ForEach([Pane.home, .time, .meetings]) { row($0) }
          }
          Section("Herramientas") {
            ForEach([Pane.voice, .ai, .tools]) { row($0) }
          }
        }
        .listStyle(.sidebar)
        List(selection: $pane) { row(.settings) }
          .listStyle(.sidebar)
          .scrollDisabled(true)
          .frame(height: 44)
          .padding(.bottom, 8)
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
    } detail: {
      Group {
        switch pane ?? .home {
        case .home: HomeView(app: app, settings: settings, model: model, pane: $pane)
        case .time: TimeView(app: app, tracker: app.activity)
        case .meetings: MeetingsView(app: app, meetings: app.meetings)
        case .voice: VoiceView(app: app, settings: settings, model: model)
        case .ai: AIView(app: app, claude: app.claude)
        case .tools: ToolsView(app: app, brew: app.brew)
        case .settings: SettingsView(app: app, settings: settings)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(WindowMaterial(material: .underWindowBackground).ignoresSafeArea())
    }
    .tint(Theme.violet)
    .onAppear {
      if let p = model.requestedPane {
        pane = p
        model.requestedPane = nil
      }
    }
    .onChange(of: model.requestedPane) { _, p in
      if let p {
        pane = p
        model.requestedPane = nil
      }
    }
  }

  func row(_ p: Pane) -> some View {
    Label {
      HStack {
        Text(p.title)
        Spacer()
        if p == .time, app.activity.enabled, app.activity.todayTotals.work >= 60 {
          Text(ActivityTotals.format(app.activity.todayTotals.work, short: true))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
    } icon: {
      IconTile(symbol: p.symbol, tint: p.tint, size: 20)
    }
    .tag(p)
  }
}

/// Voz: el historial de dictados, el diccionario y los estilos, en una sola sección con pestañas.
struct VoiceView: View {
  let app: AppDelegate
  @Bindable var settings: AppSettings
  @Bindable var model: AppModel
  enum Tab: String, CaseIterable, Identifiable {
    case history = "Historial", dictionary = "Diccionario", styles = "Estilos"
    var id: String { rawValue }
  }
  @State private var tab: Tab = .history

  var subtitle: String {
    switch tab {
    case .history: return "Tus últimos 100 dictados. Se guardan solo en este Mac."
    case .dictionary: return "Nombres, marcas y términos que Faro debe escribir exactamente así."
    case .styles: return "Cómo queda el texto según la app donde dictas."
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        PaneHeader(title: "Voz", subtitle: subtitle)
        Picker("", selection: $tab) {
          ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
      }
      .padding(.horizontal, 28)
      .padding(.top, 28)
      .frame(maxWidth: 880, alignment: .leading)
      .frame(maxWidth: .infinity)
      switch tab {
      case .history: HistoryView(app: app, model: model)
      case .dictionary: DictionaryView(settings: settings)
      case .styles: StylesView(settings: settings)
      }
    }
  }
}

struct EngineBadge: View {
  let status: EngineStatus
  let paused: Bool
  var body: some View {
    let (text, color): (String, Color) = {
      if paused { return ("En pausa", .orange) }
      switch status {
      case .ready: return ("Listo", .green)
      case .loading: return ("Cargando motor…", .secondary)
      case .failed: return ("Motor con error", .red)
      }
    }()
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(text).font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Título grande de cada pantalla.
struct PaneHeader: View {
  let title: String
  let subtitle: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 26, weight: .bold))
      Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
