import FaroCore
import SwiftUI

struct SettingsView: View {
  let app: AppDelegate
  @Bindable var settings: AppSettings
  @State private var apiKey = ""
  @State private var keyMessage: String?
  @State private var refresh = 0
  @State private var launch = false
  @State private var microphones: [(uid: String, name: String)] = []

  var body: some View {
    let _ = refresh
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PaneHeader(title: "Ajustes", subtitle: "Permisos, limpieza con Claude y comportamiento de Faro.")

        SettingsSection(title: "Permisos de macOS", symbol: "lock.shield") {
          PermissionRow(title: "Micrófono", detail: "Para escucharte mientras mantienes fn.", ok: Permissions.microphone) {
            Task {
              _ = await Permissions.requestMicrophone()
              refresh += 1
            }
          }
          Divider()
          PermissionRow(title: "Accesibilidad", detail: "Para escuchar la tecla fn, leer el campo donde escribes y pegar.", ok: Permissions.accessibility) {
            Permissions.promptAccessibility()
            Permissions.open("Privacy_Accessibility")
          }
          Divider()
          PermissionRow(title: "Monitoreo de entrada", detail: "Para detectar la tecla fn en todas las apps.", ok: Permissions.inputMonitoring) {
            Permissions.open("Privacy_ListenEvent")
          }
          Divider()
          PermissionRow(title: "Grabación de pantalla y audio del sistema", detail: "Solo para grabar el audio del Mac en videollamadas.", ok: Permissions.screenCapture) {
            Permissions.requestScreenCapture()
            Permissions.open("Privacy_ScreenCapture")
          }
          Text("Después de dar Accesibilidad, cierra Faro y vuelve a abrirla. En Ajustes del Sistema → Teclado, pon «Pulsar la tecla 🌐 para» en «No hacer nada».")
            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }

        SettingsSection(title: "Limpieza con Claude", symbol: "sparkles") {
          Toggle("Solo local: nunca enviar texto a Claude", isOn: $settings.localOnly)
          Text("Tu voz siempre se queda en este Mac. Con la limpieza activa, solo el texto transcrito y el texto alrededor del cursor van a Claude Haiku.")
            .font(.caption).foregroundStyle(.secondary)
          Divider()
          HStack {
            SecureField(app.apiKey == nil ? "Clave de API de Anthropic" : "Clave guardada en el Llavero", text: $apiKey)
              .textFieldStyle(.roundedBorder)
            Button("Guardar") {
              let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
              keyMessage = app.saveAPIKey(key) ? "Clave guardada" : "No se pudo guardar la clave"
              apiKey = ""
            }
            .disabled(apiKey.isEmpty)
          }
          if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
        }

        SettingsSection(title: "Copiloto de reuniones", symbol: "text.bubble") {
          HStack {
            TextField("Carpeta de notas (vacío = desactivado)", text: $settings.copilotNotesFolder)
              .textFieldStyle(.roundedBorder)
            Button("Elegir...") { pickCopilotFolder() }
          }
          Text("Un archivo .md por tema (tu producto, tus servicios, tus proyectos). El copiloto solo responde con lo que dicen estas notas, y solo el texto va a Claude.")
            .font(.caption).foregroundStyle(.secondary)
        }

        SettingsSection(title: "Comportamiento", symbol: "slider.horizontal.3") {
          Picker("Indicador al dictar", selection: $settings.indicatorStyle) {
            ForEach(IndicatorStyle.allCases) { Text($0.title).tag($0) }
          }
          .onChange(of: settings.indicatorStyle) { _, v in
            app.overlay.style = v
            // Vista previa de cómo se ve al dictar.
            app.overlay.show(.notice("Así se ve el indicador"))
          }
          if settings.indicatorStyle != .menuBar {
            Toggle(settings.indicatorStyle == .island ? "Mostrar la isla siempre (también en reposo)" : "Mostrar la píldora en reposo", isOn: $settings.showIdlePill)
              .onChange(of: settings.showIdlePill) { _, v in
                app.overlay.showIdle = v
                app.overlay.show(.hidden)
              }
            Toggle("Ocultarla viendo videos (Stremio, QuickTime, IINA, o YouTube y Netflix en pantalla completa)", isOn: $settings.hidePillWhenWatching)
              .disabled(!settings.showIdlePill)
            if settings.indicatorStyle == .island {
              Toggle("Mostrar el volumen y el brillo en la isla (en vez del indicador de macOS)", isOn: $settings.volumeBrightnessInIsland)
                .onChange(of: settings.volumeBrightnessInIsland) { _, v in app.mediaKeys.enabled = v }
              Toggle("Con un monitor externo, mover la isla a la pantalla donde está el puntero", isOn: $settings.islandFollowsPointer)
                .onChange(of: settings.islandFollowsPointer) { _, v in app.overlay.followsPointer = v }
              Toggle("Ocultarla también en cualquier app en pantalla completa", isOn: $settings.hideInFullscreen)
                .disabled(!settings.showIdlePill || !settings.hidePillWhenWatching)
            }
          }
        }

        SettingsSection(title: "Scroll", symbol: "arrow.up.arrow.down") {
          Toggle("Invertir el scroll del mouse", isOn: $settings.invertMouseScroll)
            .onChange(of: settings.invertMouseScroll) { _, _ in app.scroll.inversion = settings.scrollInversion }
          Toggle("Invertir el scroll del trackpad y del Magic Mouse", isOn: $settings.invertTrackpadScroll)
            .onChange(of: settings.invertTrackpadScroll) { _, _ in app.scroll.inversion = settings.scrollInversion }
          Toggle("En juegos, un paso por cada muesca de la rueda (Minecraft)", isOn: $settings.steppedScrollInGames)
            .onChange(of: settings.steppedScrollInGames) { _, v in app.scroll.steppedInGames = v }
          Text("Quita el scroll suave y la inercia mientras juegas, para que el inventario avance de a un espacio. Fuera del juego el scroll sigue igual.")
            .font(.caption).foregroundStyle(.secondary)
          Text("macOS usa una sola dirección para todo. Así puedes dejar el trackpad natural y la rueda del mouse al revés, o al contrario. Necesita el permiso de Accesibilidad.")
            .font(.caption).foregroundStyle(.secondary)
        }

        if settings.indicatorStyle == .island {
          SettingsSection(title: "Isla en reposo", symbol: "rectangle.topthird.inset.filled") {
            IdlePreview(state: app.overlay.state)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 6)
            Picker("A la izquierda del notch", selection: $settings.idleLeft) {
              ForEach(IdleItem.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.idleLeft) { _, v in withAnimation(.spring(response: 0.44, dampingFraction: 0.78)) { app.overlay.state.idleLeft = v } }
            Picker("A la derecha del notch", selection: $settings.idleRight) {
              ForEach(IdleItem.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.idleRight) { _, v in withAnimation(.spring(response: 0.44, dampingFraction: 0.78)) { app.overlay.state.idleRight = v } }
            Text("La música, Claude trabajando y los avisos siguen apareciendo encima de esto. Si no tienes los límites activos, en su lugar sale el ícono de Faro.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        SettingsSection(title: "Sistema", symbol: "macwindow") {
          Toggle("Abrir Faro al iniciar sesión", isOn: $launch)
            .onChange(of: launch) { _, v in app.launchAtLogin = v }
          Toggle("Pausar el dictado", isOn: $settings.paused)
            .onChange(of: settings.paused) { _, _ in app.updateMenu() }
        }

        SettingsSection(title: "Motor", symbol: "cpu") {
          LabeledContent("Transcripción", value: "Whisper large-v3-turbo, local")
          LabeledContent("Limpieza", value: AnthropicCleaner.model)
          LabeledContent("Atajo", value: "Mantener fn · doble toque para manos libres")
          Picker("Micrófono", selection: $settings.microphone) {
            Text("Automático").tag(MicInfo.auto)
            Text("El del sistema").tag(MicInfo.system)
            ForEach(microphones, id: \.uid) { Text($0.name).tag($0.uid) }
            if settings.microphone != MicInfo.auto, settings.microphone != MicInfo.system,
              !microphones.contains(where: { $0.uid == settings.microphone }) {
              Text("No conectado (se usa Automático)").tag(settings.microphone)
            }
          }
          .onAppear { microphones = MicInfo.availableInputs() }
          Text("Automático usa el micrófono del Mac cuando tienes AirPods u otros audífonos Bluetooth: su micrófono se oye mucho peor y la música baja de calidad mientras dictas. Aplica al dictado y a las reuniones.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .onAppear { launch = app.launchAtLogin }
    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh += 1 }
  }

  private func pickCopilotFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message = "Elige la carpeta con las notas de contexto del copiloto"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.copilotNotesFolder = url.path
  }
}

struct SettingsSection<Content: View>: View {
  let title: String
  let symbol: String
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: symbol).font(.headline)
      Card { VStack(alignment: .leading, spacing: 10) { content } }
    }
  }
}

struct PermissionRow: View {
  let title: String
  let detail: String
  let ok: Bool
  let action: () -> Void
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .font(.title3)
        .foregroundStyle(ok ? .green : .orange)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if ok {
        Text("Concedido").font(.caption).foregroundStyle(.secondary)
      } else {
        Button("Dar permiso", action: action).buttonStyle(.borderedProminent)
      }
    }
  }
}

/// Vista previa de la isla en reposo, con un notch dibujado.
struct IdlePreview: View {
  let state: OverlayState
  var body: some View {
    let notchW: CGFloat = 150
    let notchH: CGFloat = 32
    let shoulder = state.idleShoulder
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.5), Color(red: 0.35, green: 0.3, blue: 0.55)], startPoint: .top, endPoint: .bottom))
        .frame(width: notchW + 2 * shoulder + 120, height: 64)
      IslandShape(topRadius: 6, bottomRadius: 11)
        .fill(.black)
        .frame(width: notchW + 2 * shoulder + 12, height: notchH)
      IdleIsland(state: state, notchW: notchW, notchH: notchH, peek: false)
        .frame(width: notchW + 2 * shoulder, height: notchH)
        .foregroundStyle(.white)
    }
    .animation(.spring(response: 0.44, dampingFraction: 0.78), value: shoulder)
  }
}
