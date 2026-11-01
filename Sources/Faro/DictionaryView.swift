import FaroCore
import SwiftUI

struct DictionaryView: View {
  @Bindable var settings: AppSettings
  @State private var newWord = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PaneHeader(title: "Diccionario", subtitle: "Nombres, marcas y términos que Faro debe escribir exactamente así.")
        Card {
          HStack {
            TextField("Agregar palabra, por ejemplo Supabase o el nombre de tu empresa", text: $newWord)
              .textFieldStyle(.plain)
              .font(.body)
              .onSubmit(add)
            Button("Agregar", action: add)
              .buttonStyle(.borderedProminent)
              .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        FlowLayout(spacing: 8) {
          ForEach(settings.words, id: \.self) { word in
            HStack(spacing: 6) {
              Text(word)
              Button {
                settings.words.removeAll { $0 == word }
              } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .help("Quitar «\(word)»")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.violet.opacity(0.10)))
            .overlay(Capsule().stroke(Theme.violet.opacity(0.25)))
          }
        }
        Text("Whisper recibe estas palabras como vocabulario y Claude las usa para corregir lo que suene parecido. \(settings.words.count) palabras.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(28)
      .frame(maxWidth: 820, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  func add() {
    let w = newWord.trimmingCharacters(in: .whitespaces)
    guard !w.isEmpty, !settings.words.contains(w) else { return }
    settings.words.append(w)
    newWord = ""
  }
}
