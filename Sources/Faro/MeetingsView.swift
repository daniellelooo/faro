import FaroCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsView: View {
  let app: AppDelegate
  @Bindable var meetings: MeetingController
  @State private var includeSystemAudio = false
  @State private var useCopilot = false
  @State private var selected: UUID?
  @State private var confirmDiscard = false
  @State private var selecting = false
  /// Grupos plegados (se recuerdan entre aperturas).
  @AppStorage("gruposPlegados") private var collapsedRaw = ""
  /// Encabezado sobre el que se está arrastrando una grabación ("" = Sin grupo).
  @State private var dropTarget: String?
  @State private var selection: Set<UUID> = []
  @State private var pendingDelete: Set<UUID> = []
  @State private var groupPrompt = GroupPrompt()

  var body: some View {
    if let id = selected, let m = meetings.meetings.first(where: { $0.id == id }) {
      MeetingDetailView(app: app, meetings: meetings, meeting: m) { selected = nil }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          PaneHeader(title: "Reuniones", subtitle: "Graba en persona o en videollamada. La transcripción se hace en este Mac mientras hablan.")
          if meetings.isRecording { recordingCard } else { startCard }
          if !meetings.isRecording { ImportAudioCard(meetings: meetings) }
          if let msg = meetings.busyMessage {
            Text(msg).font(.callout).foregroundStyle(.orange)
          }
          let past = meetings.meetings.filter { $0.id != meetings.current?.id }
          if !past.isEmpty {
            listHeader
            ForEach(MeetingGroups.sections(past)) { section in
              VStack(alignment: .leading, spacing: 8) {
                if let name = section.name { groupHeader(name, count: section.meetings.count) }
                else if MeetingGroups.sections(past).count > 1 {
                  Text("Sin grupo").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(dropHighlight(""))
                    .dropDestination(for: String.self) { items, _ in drop(items, into: nil) } isTargeted: { dropTarget = $0 ? "" : (dropTarget == "" ? nil : dropTarget) }
                }
                if section.name.map({ !collapsed.contains($0) }) ?? true {
                  ForEach(section.meetings) { m in row(m) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
              }
              .padding(.leading, section.name == nil ? 0 : 4)
            }
          }
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .confirmationDialog(pendingDelete.count == 1 ? "¿Eliminar esta grabación?" : "¿Eliminar \(pendingDelete.count) grabaciones?",
                          isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
        Button("Eliminar", role: .destructive) {
          meetings.delete(pendingDelete)
          selection.subtract(pendingDelete)
          pendingDelete = []
          if selection.isEmpty { selecting = false }
        }
      } message: {
        Text("Se borran el audio, la transcripción y el resumen. No se puede deshacer.")
      }
      .groupPrompt($groupPrompt) { name, ids in
        if let old = groupPrompt.renaming { meetings.renameGroup(old, to: name) }
        else if ids.isEmpty { meetings.nextGroup = MeetingGroups.normalized(name) }
        else { meetings.setGroup(name, for: ids) }
        selection = []
        selecting = false
      }
    }
  }

  var listHeader: some View {
    HStack {
      Text("Anteriores").font(.headline)
      Spacer()
      if selecting {
        Text(selection.isEmpty ? "Elige grabaciones" : "\(selection.count) seleccionadas").font(.callout).foregroundStyle(.secondary)
        GroupMenu(meetings: meetings, ids: selection, prompt: $groupPrompt).disabled(selection.isEmpty)
        Button("Eliminar", role: .destructive) { pendingDelete = selection }.disabled(selection.isEmpty)
        Button("Listo") {
          selecting = false
          selection = []
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button("Seleccionar") { selecting = true }
      }
    }
  }

  var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

  func toggleGroup(_ name: String) {
    var c = collapsed
    if c.contains(name) { c.remove(name) } else { c.insert(name) }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { collapsedRaw = c.sorted().joined(separator: "\n") }
  }

  func groupHeader(_ name: String, count: Int) -> some View {
    let isCollapsed = collapsed.contains(name)
    return HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold)).foregroundStyle(.secondary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
        Image(systemName: "folder.fill").foregroundStyle(Theme.violet)
        Text(name).font(.subheadline.weight(.semibold))
        Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.07)))
        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture { toggleGroup(name) }
      .padding(.vertical, 4).padding(.horizontal, 6)
      .background(dropHighlight(name))
      .dropDestination(for: String.self) { items, _ in drop(items, into: name) } isTargeted: { over in
        dropTarget = over ? name : (dropTarget == name ? nil : dropTarget)
      }
      .help(isCollapsed ? "Mostrar las grabaciones del grupo" : "Ocultar las grabaciones del grupo")
      Menu {
        Button("Renombrar el grupo…") { groupPrompt = GroupPrompt(isPresented: true, name: name, ids: [], renaming: name) }
        Button("Seleccionar todo el grupo") {
          selecting = true
          selection.formUnion(meetings.meetings.filter { $0.group == name }.map(\.id))
        }
        Button("Desagrupar") { meetings.setGroup(nil, for: Set(meetings.meetings.filter { $0.group == name }.map(\.id))) }
      } label: { Image(systemName: "ellipsis") }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
    }
  }

  /// Suelta grabaciones (por su id) en un grupo; si la arrastrada estaba seleccionada, se mueven todas las seleccionadas.
  func drop(_ items: [String], into group: String?) -> Bool {
    var ids = Set(items.compactMap(UUID.init(uuidString:)))
    guard !ids.isEmpty else { return false }
    if selecting, !ids.isDisjoint(with: selection) { ids.formUnion(selection) }
    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { meetings.setGroup(group, for: ids) }
    if let group, collapsed.contains(group) { toggleGroup(group) }
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    dropTarget = nil
    return true
  }

  func dropHighlight(_ key: String) -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(dropTarget == key ? Theme.violet.opacity(0.16) : .clear)
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(dropTarget == key ? Theme.violet : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
  }

  func row(_ m: Meeting) -> some View {
    HStack(spacing: 10) {
      if selecting {
        Image(systemName: selection.contains(m.id) ? "checkmark.circle.fill" : "circle")
          .font(.title3).foregroundStyle(selection.contains(m.id) ? Theme.violet : .secondary)
      }
      MeetingRow(meeting: m)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if selecting {
        if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
      } else {
        selected = m.id
      }
    }
    .draggable(m.id.uuidString) {
      // Vista mientras se arrastra: el título (y cuántas van, si hay varias seleccionadas).
      let n = selecting && selection.contains(m.id) ? selection.count : 1
      Label(n > 1 ? "\(n) grabaciones" : m.displayTitle, systemImage: "waveform")
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Theme.violet))
        .foregroundStyle(.white)
    }
    .contextMenu {
      Button("Abrir") { selected = m.id }
      GroupMenu(meetings: meetings, ids: [m.id], prompt: $groupPrompt)
      Divider()
      Button("Eliminar", role: .destructive) { pendingDelete = [m.id] }
    }
  }

  var startCard: some View {
    Card(padding: 22) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 14) {
          ZStack {
            Circle().fill(Theme.brandGradient).frame(width: 46, height: 46)
            Image(systemName: "person.3.fill").foregroundStyle(.white)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text("Graba una reunión").font(.title3.weight(.semibold))
            Text("Al terminar tendrás la transcripción, un resumen, las decisiones y las tareas.").font(.callout).foregroundStyle(.secondary)
          }
        }
        HStack {
          Text("Guardar en")
          NextGroupMenu(meetings: meetings, prompt: $groupPrompt)
          Spacer()
        }
        Toggle(isOn: $includeSystemAudio) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Es una videollamada")
            Text("Incluye el audio del Mac (Meet, Zoom, Teams) además del micrófono. Pide el permiso de grabación de pantalla la primera vez.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        Toggle(isOn: $useCopilot) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Copiloto en vivo")
            Text("Cuando te pregunten algo que cubren tus notas de contexto, la respuesta aparece en un panel que no se ve al compartir pantalla. La carpeta de notas se elige en Ajustes.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        HStack(spacing: 6) {
          Image(systemName: "info.circle")
          Text("Avísales a los presentes que vas a grabar. Deja el Mac abierto: con la tapa cerrada la grabación se detiene.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        Button {
          meetings.busyMessage = nil
          if includeSystemAudio && !Permissions.screenCapture { Permissions.requestScreenCapture() }
          Task {
            await meetings.start(includeSystemAudio: includeSystemAudio, copilot: useCopilot)
            app.updateMenu()
          }
        } label: {
          Label("Empezar a grabar", systemImage: "record.circle").frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
  }

  var recordingCard: some View {
    Card(padding: 22) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .center, spacing: 14) {
          Circle().fill(meetings.isPaused ? Color.yellow : Color.red).frame(width: 12, height: 12)
            .shadow(color: (meetings.isPaused ? Color.yellow : Color.red).opacity(0.6), radius: 6)
          Text(meetings.isPaused ? "En pausa" : "Grabando").font(.title3.weight(.semibold))
          Text(MeetingClock.text(meetings.elapsed))
            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
          Spacer()
          LevelBars(level: meetings.level).foregroundStyle(Theme.violet).colorMultiply(Theme.violet)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Transcripción en vivo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          if meetings.liveSegments.isEmpty {
            Text("El primer tramo aparece tras unos 15 segundos de conversación.").font(.callout).foregroundStyle(.secondary)
          } else {
            ForEach(meetings.liveSegments.suffix(4)) { s in
              HStack(alignment: .top, spacing: 8) {
                Text(MeetingExport.clock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(s.text).font(.callout)
              }
            }
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        HStack {
          Button(role: .destructive) { confirmDiscard = true } label: { Text("Descartar") }
          Spacer()
          Button {
            meetings.togglePause()
          } label: {
            Label(meetings.isPaused ? "Reanudar" : "Pausar", systemImage: meetings.isPaused ? "play.fill" : "pause.fill")
              .padding(.horizontal, 6).padding(.vertical, 2)
          }
          .controlSize(.large)
          Button {
            Task {
              await meetings.stop()
              app.updateMenu()
            }
          } label: {
            Label("Terminar y resumir", systemImage: "stop.circle").padding(.horizontal, 6).padding(.vertical, 2)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        }
      }
    }
    .confirmationDialog("¿Descartar la grabación?", isPresented: $confirmDiscard) {
      Button("Descartar", role: .destructive) {
        Task {
          await meetings.discard()
          app.updateMenu()
        }
      }
    } message: {
      Text("Se borra el audio y lo transcrito. No se puede deshacer.")
    }
  }
}

struct StatusChip: View {
  let status: Meeting.Status
  var body: some View {
    let (text, color): (String, Color) = {
      switch status {
      case .recording: return ("Grabando", .red)
      case .transcribing: return ("Transcribiendo…", Theme.violet)
      case .summarizing: return ("Resumiendo…", Theme.violet)
      case .ready: return ("Lista", .green)
      case .interrupted: return ("Interrumpida", .orange)
      case .failed: return ("Sin voz", .secondary)
      }
    }()
    Badge(text: text, color: color)
  }
}

struct MeetingRow: View {
  let meeting: Meeting
  var body: some View {
    Card(padding: 14) {
      HStack(spacing: 12) {
        Image(systemName: meeting.includesSystemAudio ? "video" : "person.2")
          .frame(width: 28, height: 28)
          .background(Circle().fill(Theme.violet.opacity(0.12)))
          .foregroundStyle(Theme.violet)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(meeting.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
            StatusChip(status: meeting.status)
          }
          Text("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MeetingExport.clock(meeting.duration))")
            .font(.caption).foregroundStyle(.secondary)
          if let s = meeting.summary?.summary {
            Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }
    }
    .contentShape(Rectangle())
  }
}

struct MeetingDetailView: View {
  let app: AppDelegate
  @Bindable var meetings: MeetingController
  let meeting: Meeting
  let back: () -> Void
  enum Tab: String, CaseIterable { case summary = "Resumen", tasks = "Tareas", transcript = "Transcripción" }
  @State private var tab: Tab = .summary
  @State private var copied = false
  @State private var confirmDelete = false
  @State private var query = ""
  @State private var groupPrompt = GroupPrompt()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Button(action: back) { Label("Reuniones", systemImage: "chevron.left") }.buttonStyle(.link)
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(meeting.displayTitle).font(.system(size: 24, weight: .bold, design: .rounded))
            HStack(spacing: 8) {
              Text("\(meeting.startedAt.formatted(date: .long, time: .shortened)) · \(MeetingExport.clock(meeting.duration))")
                .font(.callout).foregroundStyle(.secondary)
              StatusChip(status: meeting.status)
              if let g = meeting.group {
                Label(g, systemImage: "folder.fill").font(.caption.weight(.medium)).foregroundStyle(Theme.violet)
              }
            }
          }
          Spacer()
          HStack(spacing: 8) {
            Button(copied ? "Copiado" : "Copiar en Markdown") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(MeetingExport.markdown(meeting), forType: .string)
              copied = true
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            Menu {
              Button("Mostrar el audio en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meetings.store.audioURL(meeting.id)])
              }
              Button("Volver a resumir") { Task { await meetings.summarize(meeting.id) } }
              Button("Volver a transcribir el audio") { Task { await meetings.retranscribe(meeting.id) } }
              GroupMenu(meetings: meetings, ids: [meeting.id], prompt: $groupPrompt)
              Divider()
              Button("Eliminar la reunión", role: .destructive) { confirmDelete = true }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
          }
        }
        if let e = meeting.error { Text(e).font(.callout).foregroundStyle(.orange) }
        if meeting.status == .interrupted {
          Card {
            HStack {
              Text("Faro se cerró durante esta reunión. Lo transcrito hasta ese momento se guardó.").font(.callout)
              Spacer()
              Button("Resumir lo que quedó") { Task { await meetings.summarize(meeting.id) } }
                .buttonStyle(.borderedProminent)
                .disabled(meeting.segments.isEmpty)
            }
          }
        }
        Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 360)
        switch tab {
        case .summary: summaryView
        case .tasks: tasksView
        case .transcript: transcriptView
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .groupPrompt($groupPrompt) { name, ids in meetings.setGroup(name, for: ids) }
    .confirmationDialog("¿Eliminar esta reunión?", isPresented: $confirmDelete) {
      Button("Eliminar", role: .destructive) {
        meetings.delete(meeting.id)
        back()
      }
    } message: {
      Text("Se borran el audio, la transcripción y el resumen.")
    }
  }

  @ViewBuilder var summaryView: some View {
    if meeting.status == .summarizing || meeting.status == .transcribing {
      Card {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(meeting.status == .transcribing ? "Terminando la transcripción…" : "Claude está resumiendo la reunión…")
        }
      }
    } else if let s = meeting.summary {
      VStack(alignment: .leading, spacing: 14) {
        Card { Text(s.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        if !s.keyPoints.isEmpty { listSection("Puntos clave", "lightbulb", s.keyPoints) }
        if !s.decisions.isEmpty { listSection("Decisiones", "checkmark.seal", s.decisions) }
        if !s.openQuestions.isEmpty { listSection("Pendientes", "questionmark.circle", s.openQuestions) }
      }
    } else {
      Card {
        Text(app.settings.localOnly ? "Con «Solo local» activo no se generan resúmenes. La transcripción completa está en su pestaña." : "Todavía no hay resumen.")
          .foregroundStyle(.secondary)
      }
    }
  }

  func listSection(_ title: String, _ symbol: String, _ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: symbol).font(.headline)
      Card {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(items, id: \.self) { item in
            HStack(alignment: .top, spacing: 8) {
              Circle().fill(Theme.violet).frame(width: 5, height: 5).padding(.top, 7)
              Text(item).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
  }

  @ViewBuilder var tasksView: some View {
    let tasks = meeting.summary?.tasks ?? []
    if tasks.isEmpty {
      Card { Text("No salieron tareas de esta reunión.").foregroundStyle(.secondary) }
    } else {
      Card {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(tasks) { t in
            HStack(alignment: .top, spacing: 10) {
              Button { meetings.toggleTask(meeting.id, t) } label: {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                  .font(.title3)
                  .foregroundStyle(t.done ? Theme.violet : .secondary)
              }
              .buttonStyle(.plain)
              VStack(alignment: .leading, spacing: 2) {
                Text(t.description).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                let extra = [t.owner, t.due].compactMap { $0 }.joined(separator: " · ")
                if !extra.isEmpty { Text(extra).font(.caption).foregroundStyle(.secondary) }
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder var transcriptView: some View {
    TextField("Buscar en la transcripción", text: $query).textFieldStyle(.roundedBorder).frame(width: 300)
    let segs = query.isEmpty ? meeting.segments : meeting.segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
    Card {
      LazyVStack(alignment: .leading, spacing: 10) {
        if segs.isEmpty { Text("Sin texto.").foregroundStyle(.secondary) }
        ForEach(segs) { s in
          HStack(alignment: .top, spacing: 10) {
            Text(MeetingExport.clock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(s.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

/// Traer una grabación hecha en otro lado: Notas de voz del iPhone (por AirDrop), una grabadora, un audio de WhatsApp.
struct ImportAudioCard: View {
  let meetings: MeetingController
  @State private var targeted = false
  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "iphone.and.arrow.forward").font(.title2).foregroundStyle(Theme.violet).frame(width: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text("¿Grabaste con el iPhone?").font(.headline)
        Text("Pásalo por AirDrop y suéltalo aquí, o elígelo. Faro lo transcribe y lo resume igual que una grabación propia\(meetings.nextGroup.map { ", y lo guarda en «\($0)»" } ?? "").")
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button("Importar audio…") { pick() }
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(targeted ? Theme.violet.opacity(0.1) : Theme.cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
      .strokeBorder(targeted ? Theme.violet : Theme.subtleBorder, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [6, 4] : [])))
    .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
      for p in providers {
        _ = p.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in await meetings.importAudio(url) }
        }
      }
      return !providers.isEmpty
    }
  }

  func pick() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]
    panel.allowsMultipleSelection = true
    panel.message = "Elige las grabaciones que quieres transcribir"
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { Task { await meetings.importAudio(url) } }
  }
}

/// Pedir el nombre de un grupo (nuevo o para renombrar).
struct GroupPrompt {
  var isPresented = false
  var name = ""
  /// A qué grabaciones se aplica; vacío = el grupo de las próximas grabaciones.
  var ids: Set<UUID> = []
  var renaming: String?
}

extension View {
  func groupPrompt(_ prompt: Binding<GroupPrompt>, onSave: @escaping (String, Set<UUID>) -> Void) -> some View {
    alert(prompt.wrappedValue.renaming == nil ? "Nuevo grupo" : "Renombrar el grupo", isPresented: prompt.isPresented) {
      TextField("Por ejemplo, Visualización de datos", text: prompt.name)
      Button(prompt.wrappedValue.renaming == nil ? "Crear" : "Guardar") {
        let name = prompt.wrappedValue.name
        if MeetingGroups.normalized(name) != nil { onSave(name, prompt.wrappedValue.ids) }
      }
      Button("Cancelar", role: .cancel) {}
    } message: {
      Text("Agrupa las grabaciones de una misma materia o proyecto.")
    }
  }
}

/// Mover grabaciones a un grupo existente, a uno nuevo, o sacarlas del grupo.
struct GroupMenu: View {
  let meetings: MeetingController
  let ids: Set<UUID>
  @Binding var prompt: GroupPrompt
  var body: some View {
    Menu("Mover a grupo") {
      ForEach(meetings.groupNames, id: \.self) { name in
        Button(name) { meetings.setGroup(name, for: ids) }
      }
      if !meetings.groupNames.isEmpty { Divider() }
      Button("Nuevo grupo…") { prompt = GroupPrompt(isPresented: true, name: "", ids: ids) }
      if meetings.meetings.contains(where: { ids.contains($0.id) && $0.group != nil }) {
        Button("Quitar del grupo") { meetings.setGroup(nil, for: ids) }
      }
    }
    .fixedSize()
  }
}

/// Dónde se guardan las próximas grabaciones e importaciones.
struct NextGroupMenu: View {
  @Bindable var meetings: MeetingController
  @Binding var prompt: GroupPrompt
  var body: some View {
    Menu {
      Button("Sin grupo") { meetings.nextGroup = nil }
      ForEach(meetings.groupNames, id: \.self) { name in
        Button(name) { meetings.nextGroup = name }
      }
      Divider()
      Button("Nuevo grupo…") { prompt = GroupPrompt(isPresented: true, name: "", ids: []) }
    } label: {
      Label(meetings.nextGroup ?? "Sin grupo", systemImage: meetings.nextGroup == nil ? "tray" : "folder.fill")
    }
    .fixedSize()
  }
}
