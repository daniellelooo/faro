import AppKit
import FaroCore
import SwiftUI

/// Tiempo: en qué se va cada día, por proyecto y por app, con el resumen de Claude y el análisis de la semana.
struct TimeView: View {
  let app: AppDelegate
  @Bindable var tracker: ActivityTracker
  @State private var offset = 0
  @State private var showProjects = false

  var date: Date { Calendar.current.date(byAdding: .day, value: offset, to: Date())! }
  var day: String { ActivityStore.dayKey(date) }
  var isToday: Bool { offset == 0 }

  var dayTitle: String {
    if offset == 0 { return "Hoy" }
    if offset == -1 { return "Ayer" }
    return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "es_CO"))).capitalizedFirst
  }

  var body: some View {
    // Con el registro andando, la pantalla de hoy se refresca sola cada 30 segundos.
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      let spans = tracker.spans(day: day)
      let totals = ActivityTotals(spans)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          header
          if !tracker.enabled {
            disabledCard
          } else if spans.isEmpty {
            emptyCard
          } else {
            HStack(spacing: 12) {
              MetricTile(title: "Trabajo", value: ActivityTotals.format(totals.work), symbol: "briefcase.fill", tint: .blue,
                caption: isToday ? nowLine : rangeLine(totals))
              MetricTile(title: "Ocio", value: ActivityTotals.format(totals.leisure), symbol: "play.tv.fill", tint: .pink,
                caption: totals.total > 0 ? "\(Int((totals.leisure / totals.total * 100).rounded())) % del tiempo" : " ")
              MetricTile(title: "Proyectos", value: "\(totals.byProject.filter { !$0.name.isEmpty && $0.seconds >= 300 }.count)",
                symbol: "folder.fill", tint: .orange, caption: totals.byProject.first.map { $0.name.isEmpty ? "Sin proyecto" : "Más tiempo: \($0.name)" } ?? " ")
            }
            Card {
              VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Línea del día", subtitle: "Pasa el puntero por un tramo para ver qué era.")
                DayTimeline(spans: spans, tracker: tracker)
              }
            }
            HStack(alignment: .top, spacing: 12) {
              ProjectsBreakdown(spans: spans, totals: totals, tracker: tracker)
              AppsBreakdown(totals: totals)
                .frame(width: 260)
            }
          }
          SummaryCard(tracker: tracker, day: day, isToday: isToday)
          WeekCard(tracker: tracker)
          ProjectsEditor(tracker: tracker, expanded: $showProjects)
        }
        .padding(28)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
  }

  var header: some View {
    HStack(alignment: .bottom) {
      PaneHeader(title: "Tiempo", subtitle: "Cuánto trabajas, en qué proyectos y cuánto es ocio. Todo se queda en este Mac.")
      Spacer()
      HStack(spacing: 2) {
        Button { offset -= 1 } label: { Image(systemName: "chevron.left") }
          .help("Día anterior")
        Text(dayTitle).font(.callout.weight(.medium)).frame(minWidth: 120)
        Button { offset += 1 } label: { Image(systemName: "chevron.right") }
          .disabled(isToday)
          .help("Día siguiente")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(Capsule().fill(Color.primary.opacity(0.06)))
      .fixedSize()
    }
  }

  var nowLine: String {
    guard let c = tracker.current else { return "Ahora: lejos del computador" }
    if c.kind == .leisure { return "Ahora: ocio" }
    return "Ahora: \(c.project ?? "sin proyecto")"
  }

  func rangeLine(_ t: ActivityTotals) -> String {
    guard let a = t.first, let b = t.last else { return " " }
    return "De \(a.formatted(date: .omitted, time: .shortened)) a \(b.formatted(date: .omitted, time: .shortened))"
  }

  var disabledCard: some View {
    Card {
      HStack(spacing: 14) {
        IconTile(symbol: "pause.fill", tint: .gray, size: 34)
        VStack(alignment: .leading, spacing: 3) {
          Text("El registro de tiempo está apagado").font(.headline)
          Text("Actívalo para que Faro anote en qué se va tu día.").foregroundStyle(.secondary)
        }
        Spacer()
        Button("Activar") { tracker.enabled = true }.buttonStyle(.borderedProminent)
      }
    }
  }

  var emptyCard: some View {
    Card {
      HStack(spacing: 14) {
        IconTile(symbol: "clock.fill", tint: .blue, size: 34)
        VStack(alignment: .leading, spacing: 3) {
          Text(isToday ? "Faro está registrando tu día" : "Sin registro ese día").font(.headline)
          Text(isToday ? "En unos minutos aparece aquí cómo se reparte tu tiempo." : "Ese día Faro no registró actividad.")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Cifra grande con su ícono y una línea de contexto.
struct MetricTile: View {
  let title: String
  let value: String
  let symbol: String
  let tint: Color
  var caption: String = " "
  var body: some View {
    Card(padding: 16) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          IconTile(symbol: symbol, tint: tint, size: 22)
          Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
        Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}

/// El día como una franja horizontal: cada tramo con el color de su proyecto (rosado el ocio).
struct DayTimeline: View {
  let spans: [ActivitySpan]
  let tracker: ActivityTracker
  var height: CGFloat = 34
  var showsHours = true

  struct Block: Identifiable {
    var id: Date { start }
    var start: Date
    var end: Date
    var project: String?
    var kind: ActivityKind
    var label: String
  }

  /// Tramos seguidos del mismo proyecto se dibujan como uno.
  var blocks: [Block] {
    var out: [Block] = []
    for s in spans {
      if var last = out.last, last.project == s.project, last.kind == s.kind, s.start.timeIntervalSince(last.end) < 120 {
        last.end = s.end
        out[out.count - 1] = last
      } else {
        let name = s.kind == .leisure ? "Ocio" : (s.project ?? "Sin proyecto")
        out.append(Block(start: s.start, end: s.end, project: s.project, kind: s.kind, label: name))
      }
    }
    return out
  }

  var range: (Date, Date) {
    let cal = Calendar.current
    let day = cal.startOfDay(for: spans.first?.start ?? Date())
    let firstHour = spans.first.map { cal.component(.hour, from: $0.start) } ?? 8
    let lastHour = spans.last.map { cal.component(.hour, from: $0.end) + 1 } ?? 20
    let from = min(firstHour, 8)
    let to = max(min(lastHour, 24), 20)
    return (day.addingTimeInterval(Double(from) * 3600), day.addingTimeInterval(Double(to) * 3600))
  }

  var body: some View {
    let (from, to) = range
    let total = to.timeIntervalSince(from)
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05))
          ForEach(blocks) { b in
            let x = b.start.timeIntervalSince(from) / total * geo.size.width
            let w = max(2, b.end.timeIntervalSince(b.start) / total * geo.size.width)
            Rectangle()
              .fill(b.kind == .leisure ? Color.pink.opacity(0.8) : Color(nsColor: tracker.color(for: b.project)))
              .frame(width: w, height: height)
              .offset(x: x)
              .help("\(b.label) · \(b.start.formatted(date: .omitted, time: .shortened))–\(b.end.formatted(date: .omitted, time: .shortened)) · \(ActivityTotals.format(b.end.timeIntervalSince(b.start)))")
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
      .frame(height: height)
      if showsHours {
        GeometryReader { geo in
          let hours = Int(total / 3600)
          let step = hours > 12 ? 3 : 2
          ForEach(Array(stride(from: 0, through: hours, by: step)), id: \.self) { h in
            Text("\(Calendar.current.component(.hour, from: from) + h)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
              .fixedSize()
              .position(x: min(max(14, CGFloat(h) / CGFloat(hours) * geo.size.width), geo.size.width - 14), y: 6)
          }
        }
        .frame(height: 12)
      }
    }
  }
}

/// Tiempo de trabajo por proyecto, como en Timing: barra, horas y, al abrirlo, en qué se fue dentro del proyecto.
struct ProjectsBreakdown: View {
  let spans: [ActivitySpan]
  let totals: ActivityTotals
  let tracker: ActivityTracker
  @State private var open: Set<String> = []

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 10) {
        SectionTitle("Proyectos")
        let maxValue = totals.byProject.first?.seconds ?? 1
        ForEach(totals.byProject.filter { $0.seconds >= 60 }, id: \.name) { p in
          VStack(alignment: .leading, spacing: 6) {
            Button {
              if open.contains(p.name) { open.remove(p.name) } else { open.insert(p.name) }
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                  .rotationEffect(.degrees(open.contains(p.name) ? 90 : 0))
                Circle().fill(Color(nsColor: tracker.color(for: p.name))).frame(width: 9, height: 9)
                Text(p.name.isEmpty ? "Sin proyecto" : p.name).lineLimit(1).frame(width: 130, alignment: .leading)
                GeometryReader { g in
                  Capsule().fill(Color.primary.opacity(0.06))
                    .overlay(alignment: .leading) {
                      Capsule().fill(Color(nsColor: tracker.color(for: p.name)).opacity(0.85)).frame(width: max(4, g.size.width * p.seconds / maxValue))
                    }
                }
                .frame(height: 6)
                Text(ActivityTotals.format(p.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 82, alignment: .trailing)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.contains(p.name) {
              let items = ActivityDetail.topItems(spans.filter { $0.kind == .work && ($0.project ?? "") == p.name }, limit: 8)
              VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.text) { i in
                  HStack {
                    Text(i.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(ActivityTotals.format(i.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                  }
                }
              }
              .padding(.leading, 38)
              .padding(.bottom, 4)
            }
          }
        }
        if totals.leisure >= 60 {
          Divider()
          HStack(spacing: 10) {
            Color.clear.frame(width: 9)
            Circle().fill(Color.pink.opacity(0.8)).frame(width: 9, height: 9)
            Text("Ocio")
            Spacer()
            Text(ActivityTotals.format(totals.leisure)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

/// Las apps donde más tiempo se pasó.
struct AppsBreakdown: View {
  let totals: ActivityTotals
  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 10) {
        SectionTitle("Apps")
        ForEach(totals.byApp.filter { $0.seconds >= 60 }.prefix(8), id: \.name) { a in
          HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(a.bundleID, appName: a.name)).resizable().frame(width: 18, height: 18)
            Text(a.name).lineLimit(1)
            Spacer()
            Text(ActivityTotals.format(a.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

/// Resumen escrito por Claude del día elegido, con lo que quedó pendiente.
struct SummaryCard: View {
  let tracker: ActivityTracker
  let day: String
  let isToday: Bool

  var body: some View {
    let summary = tracker.store.summary(day: day)
    Card {
      VStack(alignment: .leading, spacing: 12) {
        SectionTitle(title: "Resumen del día", subtitle: summary == nil ? subtitle : nil) {
          if tracker.summarizing {
            ProgressView().controlSize(.small)
          } else if !tracker.spans(day: day).isEmpty {
            Button(summary == nil ? "Resumir con Claude" : "Volver a resumir") { Task { await tracker.summarize(day: day) } }
              .controlSize(.small)
          }
        }
        if let summary {
          Text(summary.summary).fixedSize(horizontal: false, vertical: true)
          if !summary.verdict.isEmpty {
            Label(summary.verdict, systemImage: "gauge.with.dots.needle.50percent")
              .font(.callout).foregroundStyle(.secondary)
          }
          if !summary.pending.isEmpty {
            Divider()
            Text("Quedó pendiente").font(.subheadline.weight(.semibold))
            PendingList(tracker: tracker, items: summary.pending, day: day)
          }
        }
        if let e = tracker.summaryError {
          Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
      }
    }
  }

  var subtitle: String {
    isToday
      ? "Mañana, al empezar el día, Claude escribe el resumen de hoy y lo que quedó pendiente. También puedes pedirlo ya."
      : "Este día no tiene resumen todavía."
  }
}

/// Pendientes con casilla para marcarlos como hechos (solo los del último resumen se pueden marcar).
struct PendingList: View {
  let tracker: ActivityTracker
  let items: [DaySummary.Pending]
  let day: String
  var body: some View {
    let editable = tracker.lastSummary?.day == day
    VStack(alignment: .leading, spacing: 7) {
      ForEach(items) { p in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Button { tracker.togglePending(p.id) } label: {
            Image(systemName: p.done ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(p.done ? Color.green : Color.secondary)
          }
          .buttonStyle(.plain)
          .disabled(!editable)
          Text(p.project).font(.caption.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color(nsColor: tracker.color(for: p.project)).opacity(0.18)))
          Text(p.text).strikethrough(p.done).foregroundStyle(p.done ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

/// Los últimos 7 días en barras apiladas por proyecto, y el análisis de Claude a pedido.
struct WeekCard: View {
  let tracker: ActivityTracker
  var body: some View {
    let days = tracker.lastDays()
    let maxTotal = max(3600, days.map(\.totals.total).max() ?? 0)
    Card {
      VStack(alignment: .leading, spacing: 14) {
        SectionTitle(title: "Últimos 7 días",
          subtitle: "Trabajo: \(ActivityTotals.format(days.map(\.totals.work).reduce(0, +))) · ocio: \(ActivityTotals.format(days.map(\.totals.leisure).reduce(0, +)))") {
          if tracker.analyzingWeek {
            ProgressView().controlSize(.small)
          } else {
            Button("Analizar con Claude") { Task { await tracker.analyzeWeek() } }.controlSize(.small)
          }
        }
        HStack(alignment: .bottom, spacing: 10) {
          ForEach(days, id: \.day) { d in
            VStack(spacing: 6) {
              Text(d.totals.work >= 60 ? ActivityTotals.format(d.totals.work, short: true) : " ")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
              VStack(spacing: 1) {
                if d.totals.leisure > 0 {
                  Rectangle().fill(Color.pink.opacity(0.75)).frame(height: CGFloat(d.totals.leisure / maxTotal) * 110)
                }
                ForEach(d.totals.byProject.reversed(), id: \.name) { p in
                  Rectangle().fill(Color(nsColor: tracker.color(for: p.name))).frame(height: CGFloat(p.seconds / maxTotal) * 110)
                }
              }
              .frame(height: 110, alignment: .bottom)
              .frame(maxWidth: .infinity)
              .background(alignment: .bottom) { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.025)) }
              .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
              Text(weekday(d.day)).font(.caption).foregroundStyle(d.day == ActivityStore.dayKey(Date()) ? .primary : .secondary)
            }
          }
        }
        if let w = tracker.week {
          Divider()
          Text(w.analysis).fixedSize(horizontal: false, vertical: true)
          VStack(alignment: .leading, spacing: 6) {
            ForEach(w.recommendations, id: \.self) { r in
              Label(r, systemImage: "arrow.forward.circle.fill").foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        if let e = tracker.weekError {
          Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
      }
    }
  }

  func weekday(_ key: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: key) else { return key }
    return d.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "es_CO"))).capitalizedFirst
  }
}

/// Los proyectos con nombre propio: cómo reconocerlos y de qué color pintarlos.
struct ProjectsEditor: View {
  @Bindable var tracker: ActivityTracker
  @Binding var expanded: Bool

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: 12) {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
          HStack {
            SectionTitle("Tus proyectos", subtitle: "Faro reconoce cada proyecto por estas palabras: la carpeta del repositorio, un dominio o algo del título de la ventana.")
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
              .rotationEffect(.degrees(expanded ? 90 : 0))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if expanded {
          ForEach($tracker.projects) { $p in
            HStack(spacing: 10) {
              Menu {
                ForEach(TrackedProject.palette, id: \.self) { hex in
                  Button { p.color = hex } label: {
                    Label(hex, systemImage: "circle.fill")
                  }
                }
              } label: {
                Circle().fill(Color(nsColor: NSColor(hex: p.color) ?? .gray)).frame(width: 14, height: 14)
              }
              .menuStyle(.borderlessButton)
              .menuIndicator(.hidden)
              .fixedSize()
              TextField("Nombre", text: $p.name).textFieldStyle(.roundedBorder).frame(width: 140)
              TextField("Palabras, separadas por comas", text: Binding(
                get: { p.keywords.joined(separator: ", ") },
                set: { p.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                .textFieldStyle(.roundedBorder)
              Button { tracker.projects.removeAll { $0.id == p.id } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Quitar")
            }
          }
          HStack {
            Button {
              let color = TrackedProject.palette[tracker.projects.count % TrackedProject.palette.count]
              tracker.projects.append(TrackedProject(name: "Nuevo", color: color, keywords: []))
            } label: { Label("Agregar proyecto", systemImage: "plus") }
            Spacer()
            Toggle("Registrar mi tiempo", isOn: $tracker.enabled).toggleStyle(.switch).controlSize(.small)
          }
          Text("Ocio es Stremio, sitios de video (YouTube, Netflix, Twitch) y juegos cuando están al frente; un video de fondo mientras trabajas en otra app cuenta como trabajo. Sin tocar nada por 3 minutos deja de contar. Al resumir, a Claude solo van títulos de ventanas, dominios y tiempos.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
