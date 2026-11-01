import AppKit
import FaroCore
import SwiftUI

/// Página Controles de la isla: dos tarjetas iguales. A la izquierda, barras verticales del mismo tamaño para el
/// volumen y el brillo de cada pantalla (como el Centro de control); a la derecha, el volumen de cada app.
struct ControlsPage: View {
  let state: OverlayState
  @State private var volume: Float = SystemVolume.volume ?? 0.5
  @State private var muted = SystemVolume.isMuted

  var body: some View {
    let app = state.app
    HStack(alignment: .top, spacing: IslandTheme.gap) {
      IslandCard {
        VStack(alignment: .leading, spacing: 10) {
          CardHeader(title: "Sistema", detail: nil)
          ModuleSlider(title: SystemVolume.outputName.isEmpty ? "Volumen" : SystemVolume.outputName,
                       symbol: muted || volume == 0 ? "speaker.slash.fill" : (volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"),
                       value: Binding(
                         get: { muted ? 0 : volume },
                         set: { v in
                           volume = v
                           if muted && v > 0 { SystemVolume.setMuted(false); muted = false }
                           SystemVolume.setVolume(v)
                         }))
          ForEach(app?.displays.displays ?? []) { d in
            ModuleSlider(title: d.isBuiltIn ? "Pantalla del Mac" : d.name, symbol: "sun.max.fill",
                         value: Binding(get: { d.brightness }, set: { app?.displays.setBrightness($0, for: d.id) }))
          }
        }
      }
      IslandCard {
        VStack(alignment: .leading, spacing: 12) {
          CardHeader(title: "Apps", detail: "hasta 150 %")
          if let mixer = app?.mixer {
            if mixer.apps.isEmpty {
              Spacer(minLength: 0)
              Text("Las apps que estén sonando aparecen aquí para darles su propio volumen.")
                .font(.system(size: 11.5)).foregroundStyle(IslandTheme.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
              Spacer(minLength: 0)
            } else {
              ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                  ForEach(mixer.apps) { a in
                    ModuleSlider(title: a.name, symbol: nil, icon: AppIcons.icon(a.bundleID),
                                 value: Binding(get: { mixer.gain(for: a.bundleID) / 1.5 }, set: { mixer.setGain($0 * 1.5, for: a.bundleID) }),
                                 shown: mixer.gain(for: a.bundleID), mark: 1 / 1.5)
                  }
                }
              }
            }
            if let e = mixer.lastError { Text(e).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2) }
          }
        }
      }
    }
    .onAppear {
      volume = SystemVolume.volume ?? volume
      muted = SystemVolume.isMuted
      app?.displays.refresh()
    }
  }
}

/// Fila del Centro de control: nombre y porcentaje arriba, y una barra gruesa con el ícono adentro que se arrastra.
/// Todas las filas (volumen, pantallas y apps) son idénticas.
struct ModuleSlider: View {
  let title: String
  let symbol: String?
  var icon: NSImage?
  @Binding var value: Float
  /// Valor a mostrar en porcentaje (si es distinto del de la barra, como en las apps que llegan a 150 %).
  var shown: Float?
  var mark: Float?
  static let height: CGFloat = 26

  init(title: String, symbol: String?, icon: NSImage? = nil, value: Binding<Float>, shown: Float? = nil, mark: Float? = nil) {
    self.title = title
    self.symbol = symbol
    self.icon = icon
    self._value = value
    self.shown = shown
    self.mark = mark
  }

  var body: some View {
    let v = CGFloat(min(1, max(0, value)))
    let pct = Int(((shown ?? value) * 100).rounded())
    VStack(spacing: 6) {
      HStack {
        Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        Spacer(minLength: 6)
        Text("\(pct)%").font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(pct > 100 ? Color.orange : IslandTheme.secondary)
      }
      GeometryReader { geo in
        let fill = max(Self.height, geo.size.width * v)
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.1))
          Capsule().fill(Color.white).frame(width: fill)
          if let mark {
            Capsule().fill(Color.white.opacity(0.4)).frame(width: 2, height: Self.height * 0.45)
              .offset(x: geo.size.width * CGFloat(mark) - 1)
          }
          Group {
            if let icon {
              Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else if let symbol {
              Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.7))
            }
          }
          .frame(width: Self.height, height: Self.height)
        }
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
          value = Float(min(1, max(0, g.location.x / max(geo.size.width, 1))))
        })
      }
      .frame(height: Self.height)
    }
  }
}

/// Barra vertical como las del Centro de control: se llena desde abajo, con el ícono adentro y el porcentaje arriba.
struct PillSlider: View {
  @Binding var value: Float
  let symbol: String
  let label: String
  static let size = CGSize(width: 54, height: 126)

  var body: some View {
    let v = CGFloat(min(1, max(0, value)))
    VStack(spacing: 7) {
      Text("\(Int((v * 100).rounded()))%")
        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(IslandTheme.secondary)
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.1))
        Rectangle().fill(Color.white).frame(height: Self.size.height * v)
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(v > 0.16 ? Color.black.opacity(0.75) : .white)
          .padding(.bottom, 12)
      }
      .frame(width: Self.size.width, height: Self.size.height)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .gesture(DragGesture(minimumDistance: 0).onChanged { g in
        value = Float(min(1, max(0, 1 - g.location.y / Self.size.height)))
      })
      Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(IslandTheme.secondary).lineLimit(1)
        .frame(width: Self.size.width + 14)
    }
  }
}

struct AppVolumeRow: View {
  let app: AppVolumeMixer.AppAudio
  let mixer: AppVolumeMixer
  var body: some View {
    let g = mixer.gain(for: app.bundleID)
    VStack(spacing: 7) {
      HStack(spacing: 8) {
        Image(nsImage: AppIcons.icon(app.bundleID)).resizable().frame(width: 18, height: 18)
        Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
        if !app.playing { Circle().fill(IslandTheme.tertiary).frame(width: 4, height: 4) }
        Spacer(minLength: 6)
        Text("\(Int((g * 100).rounded()))%")
          .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(g > 1 ? Color.orange : IslandTheme.secondary)
          .frame(width: 38, alignment: .trailing)
      }
      IslandSlider(symbol: nil, value: Binding(get: { g / 1.5 }, set: { mixer.setGain($0 * 1.5, for: app.bundleID) }),
                   tint: g > 1 ? .orange : .white, mark: 1 / 1.5)
    }
  }
}

/// Barra horizontal fina de la isla: se arrastra o se hace clic en cualquier punto. Todas miden lo mismo de alto.
struct IslandSlider: View {
  var symbol: String?
  @Binding var value: Float
  var tint: Color
  var mark: Float?

  init(symbol: String?, value: Binding<Float>, tint: Color, mark: Float? = nil) {
    self.symbol = symbol
    self._value = value
    self.tint = tint
    self.mark = mark
  }

  var body: some View {
    HStack(spacing: 8) {
      if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16) }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.12))
          Capsule().fill(tint).frame(width: max(6, geo.size.width * CGFloat(min(1, max(0, value)))))
          if let mark {
            Capsule().fill(Color.white.opacity(0.45)).frame(width: 2, height: 10)
              .offset(x: geo.size.width * CGFloat(mark) - 1)
          }
        }
        .frame(height: 6)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
          value = Float(min(1, max(0, g.location.x / max(geo.size.width, 1))))
        })
      }
      .frame(height: 14)
    }
  }
}
