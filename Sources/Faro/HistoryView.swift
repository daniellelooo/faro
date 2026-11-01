import FaroCore
import SwiftUI

func minutesText(_ m: Double) -> String {
  if m < 1 { return "\(Int((m * 60).rounded())) s" }
  if m < 60 { return "\(Int(m.rounded())) min" }
  return String(format: "%.1f h", m / 60)
}

struct HistoryView: View {
  let app: AppDelegate
  @Bindable var model: AppModel
  @State private var query = ""

  var body: some View {
    let _ = model.historyVersion
    let all = app.history.entries
    let filtered = query.isEmpty ? all : all.filter { $0.final.localizedCaseInsensitiveContains(query) || $0.app.localizedCaseInsensitiveContains(query) }
    let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .bottom) {
        PaneHeader(title: "Historial", subtitle: "Tus últimos 100 dictados. Se guardan solo en este Mac.")
        TextField("Buscar", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)
      }
      let stats = HistoryStats(entries: all)
      HStack(spacing: 12) {
        StatTile(value: "\(stats.wordsThisWeek)", label: "palabras esta semana", symbol: "text.word.spacing")
        StatTile(value: "\(stats.dictationsThisWeek)", label: "dictados esta semana", symbol: "mic")
        StatTile(value: minutesText(stats.minutesSavedThisWeek), label: "ahorrados vs. teclear", symbol: "hourglass")
        StatTile(value: stats.dictationsThisWeek == 0 ? "–" : String(format: "%.1f s", stats.averageSeconds), label: "de espera promedio", symbol: "bolt")
      }
      if filtered.isEmpty {
        Spacer()
        Text(all.isEmpty ? "Aquí aparecerá cada dictado." : "Ningún dictado coincide con «\(query)».")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.key) { day, items in
              VStack(alignment: .leading, spacing: 8) {
                Text(dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(items) { HistoryRow(entry: $0, compact: false) }
              }
            }
          }
        }
      }
    }
    .padding(28)
  }

  func dayTitle(_ d: Date) -> String {
    if Calendar.current.isDateInToday(d) { return "Hoy" }
    if Calendar.current.isDateInYesterday(d) { return "Ayer" }
    return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
  }
}

struct HistoryRow: View {
  let entry: HistoryEntry
  let compact: Bool
  @State private var showRaw = false
  @State private var copied = false

  var body: some View {
    Card(padding: 14) {
      HStack(alignment: .top, spacing: 12) {
        Image(nsImage: AppIcons.icon(entry.bundleID, appName: entry.app)).resizable().frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(entry.app).font(.caption.weight(.semibold))
            Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f s", entry.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if entry.usedFallback { Badge(text: "Sin limpiar", color: .orange) }
            if entry.verified == false { Badge(text: "No se pegó", color: .red) }
            Spacer()
            Button(copied ? "Copiado" : "Copiar") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(entry.final, forType: .string)
              copied = true
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .buttonStyle(.borderless)
            .font(.caption)
          }
          Text(entry.final)
            .lineLimit(compact ? 2 : nil)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          if !compact && entry.raw != entry.final {
            DisclosureGroup(isExpanded: $showRaw) {
              Text(entry.raw).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
              Text("Lo que transcribió Whisper").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
}

struct Badge: View {
  let text: String
  let color: Color
  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(color.opacity(0.14)))
  }
}
