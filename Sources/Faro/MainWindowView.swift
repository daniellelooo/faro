import FaroCore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
  case home, meetings, ai, tools, history, dictionary, styles, settings
  var id: String { rawValue }
  var title: String {
    switch self {
    case .home: return "Inicio"
    case .meetings: return "Reuniones"
    case .ai: return "IA"
    case .tools: return "Herramientas"
    case .history: return "Historial"
    case .dictionary: return "Diccionario"
    case .styles: return "Estilos"
    case .settings: return "Ajustes"
    }
  }
  var symbol: String {
    switch self {
    case .home: return "house"
    case .meetings: return "person.3"
    case .ai: return "sparkles"
    case .tools: return "wrench.and.screwdriver"
    case .history: return "clock.arrow.circlepath"
    case .dictionary: return "character.book.closed"
    case .styles: return "textformat"
    case .settings: return "gearshape"
    }
  }
}

struct MainWindowView: View {
  let app: AppDelegate
  @Bindable var settings: AppSettings
  @Bindable var model: AppModel
  @State private var pane: Pane? = .home
  @State private var appeared = false

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 30, height: 30)
          VStack(alignment: .leading, spacing: 1) {
            Text("Faro").font(.system(size: 15, weight: .semibold, design: .rounded))
            EngineBadge(status: model.engine, paused: settings.paused)
          }
        }
        .padding(.horizontal, 14)
        .padding(.top, 34)
        .padding(.bottom, 14)
        List(selection: $pane) {
          Label(Pane.home.title, systemImage: Pane.home.symbol).tag(Pane.home)
          Section("Claude y Mac") {
            ForEach([Pane.ai, .tools]) { p in Label(p.title, systemImage: p.symbol).tag(p) }
          }
          Section("Dictado") {
            ForEach([Pane.history, .meetings, .dictionary, .styles]) { p in Label(p.title, systemImage: p.symbol).tag(p) }
          }
          Section {
            Label(Pane.settings.title, systemImage: Pane.settings.symbol).tag(Pane.settings)
          }
        }
        .listStyle(.sidebar)
        Spacer(minLength: 0)
        HStack(spacing: 8) {
          Image(systemName: "rectangle.topthird.inset.filled").foregroundStyle(.secondary)
          Text("Pasa el puntero por el notch para abrir la isla · fn para dictar").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
    } detail: {
      Group {
        switch pane ?? .home {
        case .home: HomeView(app: app, settings: settings, model: model, pane: $pane)
        case .meetings: MeetingsView(app: app, meetings: app.meetings)
        case .ai: AIView(app: app, claude: app.claude)
        case .tools: ToolsView(app: app, brew: app.brew)
        case .history: HistoryView(app: app, model: model)
        case .dictionary: DictionaryView(settings: settings)
        case .styles: StylesView(settings: settings)
        case .settings: SettingsView(app: app, settings: settings)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
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
      Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
      Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
