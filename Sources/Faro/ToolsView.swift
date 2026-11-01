import FaroCore
import SwiftUI

/// Página Herramientas de la ventana: limpieza de teclado y Homebrew.
struct ToolsView: View {
  let app: AppDelegate
  @Bindable var brew: BrewService

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PaneHeader(title: "Herramientas", subtitle: "Utilidades para tu Mac. También están en la isla, en el notch.")
        Card(padding: 18) {
          HStack(spacing: 14) {
            Image(systemName: "keyboard").font(.title).foregroundStyle(Theme.violet).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text("Limpieza de teclado").font(.headline)
              Text("Bloquea todas las teclas durante 60 segundos para limpiarlo sin escribir nada.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Empezar") { app.keyboard.start() }.buttonStyle(.borderedProminent)
          }
        }
        SoundAndDisplaysCard(mixer: app.mixer, displays: app.displays)
        QuickToolsCard(quick: app.quick)
        Card(padding: 18) {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
              Image(systemName: "shippingbox").font(.title).foregroundStyle(Theme.violet).frame(width: 44)
              VStack(alignment: .leading, spacing: 2) {
                Text("Homebrew").font(.headline)
                Group {
                  if !brew.available { Text("Homebrew no está instalado.") }
                  else if brew.checking { Text("Revisando actualizaciones…") }
                  else if let t = brew.lastChecked { Text(brew.outdated.isEmpty ? "Todo al día · revisado \(t.formatted(.relative(presentation: .named)))" : "\(brew.outdated.count) paquetes con actualización") }
                  else { Text("Sin revisar todavía.") }
                }
                .font(.callout).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Revisar") { brew.check() }.disabled(brew.checking || !brew.available)
              if !brew.outdated.isEmpty {
                Button("Actualizar todo") { brew.upgrade(brew.outdated) }
                  .buttonStyle(.borderedProminent)
                  .disabled(!brew.upgrading.isEmpty)
              }
            }
            if !brew.outdated.isEmpty {
              Divider()
              ForEach(brew.outdated) { p in
                HStack {
                  Text(p.name).font(.body.monospaced())
                  if p.isCask { Badge(text: "app", color: .secondary) }
                  Spacer()
                  Text("\(p.installed) → \(p.latest)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                  if brew.upgrading.contains(p.name) {
                    ProgressView().controlSize(.small).frame(width: 80)
                  } else {
                    Button("Actualizar") { brew.upgrade([p]) }.frame(width: 80)
                  }
                }
              }
            }
            if let e = brew.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

/// Mantener despierto, temporizador y cuentagotas.
struct QuickToolsCard: View {
  let quick: QuickTools
  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 14) {
        row(symbol: "cup.and.saucer", title: "Mantener despierto",
            detail: quick.isAwake ? (quick.awakeUntil.map { "Activo hasta las " + $0.formatted(date: .omitted, time: .shortened) } ?? "Activo hasta que lo apagues")
              : "Evita que el Mac se duerma o apague la pantalla (descargas largas, presentaciones).") {
          if quick.isAwake {
            Button("Apagar") { quick.stopAwake() }
          } else {
            Button("1 h") { quick.setAwake(minutes: 60) }
            Button("3 h") { quick.setAwake(minutes: 180) }
            Button("Sin límite") { quick.setAwake(minutes: nil) }.buttonStyle(.borderedProminent)
          }
        }
        Divider()
        row(symbol: "timer", title: "Temporizador",
            detail: quick.timerRunning ? "Corre en la isla del notch y suena al terminar." : "Cuenta atrás en la isla; suena y avisa al terminar.") {
          if quick.timerRunning {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
              Text(QuickTools.clock(quick.timerRemaining(at: ctx.date))).font(.title3.monospacedDigit().weight(.semibold))
            }
            Button("Detener") { quick.stopTimer() }
          } else {
            ForEach([5, 15, 25, 50], id: \.self) { m in Button("\(m) min") { quick.startTimer(minutes: Double(m)) } }
          }
        }
        Divider()
        row(symbol: "eyedropper", title: "Color de la pantalla", detail: "Elige cualquier punto de la pantalla y se copia su color en hexadecimal.") {
          Button("Elegir color") { quick.pickColor() }.buttonStyle(.borderedProminent)
        }
      }
    }
  }

  func row<B: View>(symbol: String, title: String, detail: String, @ViewBuilder buttons: () -> B) -> some View {
    HStack(spacing: 14) {
      Image(systemName: symbol).font(.title2).foregroundStyle(Theme.violet).frame(width: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 6) { buttons() }
    }
  }
}

/// Volumen por app y brillo por pantalla (lo mismo que la página Controles de la isla).
struct SoundAndDisplaysCard: View {
  let mixer: AppVolumeMixer
  let displays: DisplayController
  var body: some View {
    Card(padding: 18) {
      VStack(alignment: .leading, spacing: 14) {
        Label("Volumen por app", systemImage: "speaker.wave.2").font(.headline)
        if mixer.apps.isEmpty {
          Text("Pon a sonar algo (Spotify, YouTube, una llamada) y aparecerá aquí para ajustarlo por separado. Del 0 al 150 %.")
            .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(mixer.apps) { a in
          HStack(spacing: 10) {
            Image(nsImage: AppIcons.icon(a.bundleID)).resizable().frame(width: 20, height: 20)
            Text(a.name).frame(width: 150, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { Double(mixer.gain(for: a.bundleID)) }, set: { mixer.setGain(Float($0), for: a.bundleID) }), in: 0...1.5)
            Text("\(Int((mixer.gain(for: a.bundleID) * 100).rounded())) %").monospacedDigit().frame(width: 50, alignment: .trailing)
          }
        }
        if let e = mixer.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
        Divider()
        Label("Brillo por pantalla", systemImage: "sun.max").font(.headline)
        ForEach(displays.displays) { d in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
              Image(systemName: d.isBuiltIn ? "laptopcomputer" : "display").frame(width: 20)
              Text(d.isBuiltIn ? "Pantalla del Mac" : d.name).frame(width: 150, alignment: .leading).lineLimit(1)
              Slider(value: Binding(get: { Double(d.brightness) }, set: { displays.setBrightness(Float($0), for: d.id) }), in: 0...1)
              Text("\(Int((d.brightness * 100).rounded())) %").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            if !d.isBuiltIn {
              Toggle(isOn: Binding(get: { d.method == .ddc }, set: { displays.setUsesDDC($0, for: d.id) })) {
                Text("Controlar el brillo real del monitor por el cable (DDC). Si al moverlo no cambia nada, déjalo apagado y Faro oscurecerá la imagen.")
                  .font(.caption).foregroundStyle(.secondary)
              }
              .toggleStyle(.checkbox)
              .padding(.leading, 30)
            }
          }
        }
      }
    }
  }
}
