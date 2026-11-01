import FaroCore
import SwiftUI

struct StylesView: View {
  @Bindable var settings: AppSettings

  static let samples: [Tone: String] = [
    .literal: "revisa el archivo de autenticación y corre las pruebas",
    .casual: "Dale, lo reviso ahorita y te aviso",
    .formal: "Quedo atento a sus comentarios. Un saludo.",
    .neutral: "La reunión quedó para el miércoles a las 3.",
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PaneHeader(title: "Estilos", subtitle: "Cómo queda el texto según la app donde dictas.")
        ForEach(AppCategory.allCases) { category in
          Card {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(category.title).font(.headline)
                  Text(category.examples).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: binding(for: category)) {
                  ForEach([Tone.literal, .casual, .formal, .neutral], id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
              }
              Text(Self.samples[settings.styles.tone(for: category)] ?? "")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  func binding(for c: AppCategory) -> Binding<Tone> {
    Binding(
      get: { settings.styles.tone(for: c) },
      set: { settings.styles.tones[c] = $0 })
  }
}
