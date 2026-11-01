import AppKit
import FaroCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Bandeja

struct ShelfPage: View {
  let state: OverlayState
  var body: some View {
    let shelf = state.app?.shelf
    let items = shelf?.items ?? []
    VStack(alignment: .leading, spacing: 10) {
      if items.isEmpty || state.dropTargeting {
        DropHint(active: state.dropTargeting, empty: items.isEmpty)
      }
      if !items.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(items) { ShelfTile(item: $0, shelf: shelf) }
          }
          .padding(.vertical, 2)
        }
        if !state.dropTargeting {
          HStack {
            Text("Arrastra un archivo hacia afuera para soltarlo donde quieras. Clic para abrir.")
              .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Button("Vaciar") { withAnimation(.spring(response: 0.35)) { shelf?.clear() } }
              .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct DropHint: View {
  let active: Bool
  let empty: Bool
  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: active ? "tray.and.arrow.down.fill" : "tray")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(active ? Color.mint : .white.opacity(0.5))
        .symbolEffect(.bounce, value: active)
      Text(active ? "Suelta para guardarlo en la bandeja" : "Arrastra archivos al notch para guardarlos aquí")
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(active ? 0.9 : 0.55))
    }
    .frame(maxWidth: .infinity)
    .frame(height: empty ? 120 : 64)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        .foregroundStyle(active ? Color.mint.opacity(0.8) : .white.opacity(0.2))
    )
    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? Color.mint.opacity(0.08) : .clear))
    .animation(.spring(response: 0.3), value: active)
  }
}

struct ShelfTile: View {
  let item: ShelfItem
  let shelf: ShelfService?
  @State private var hover = false
  var body: some View {
    VStack(spacing: 5) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
        .resizable().frame(width: 46, height: 46)
      Text(item.name).font(.system(size: 10.5)).lineLimit(2).multilineTextAlignment(.center)
        .frame(width: 78)
    }
    .padding(6)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0.055)))
    .overlay(alignment: .topTrailing) {
      if hover {
        Button { withAnimation(.spring(response: 0.3)) { shelf?.remove(item.id) } } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.plain).offset(x: 4, y: -4)
      }
    }
    .onHover { hover = $0 }
    .onTapGesture { NSWorkspace.shared.open(item.url) }
    .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    .help(item.path)
  }
}

// MARK: Portapapeles

struct ClipboardPage: View {
  let state: OverlayState
  var body: some View {
    let clip = state.app?.clipboard
    let entries = clip?.history.entries ?? []
    if entries.isEmpty {
      VStack(spacing: 6) {
        Image(systemName: "doc.on.clipboard").font(.system(size: 22)).foregroundStyle(.white.opacity(0.45))
        Text("Lo que copies aparece aquí. Solo texto, solo mientras Faro esté abierto, y nunca contraseñas.")
          .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        ScrollView {
          VStack(spacing: 4) {
            ForEach(entries) { e in ClipRow(entry: e, clip: clip, state: state) }
          }
        }
        HStack {
          Text("Clic para copiarlo de nuevo").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
          Spacer()
          Button("Borrar historial") { withAnimation { clip?.clear() } }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
      }
    }
  }
}

struct ClipRow: View {
  let entry: ClipboardHistory.Entry
  let clip: ClipboardService?
  let state: OverlayState
  @State private var hover = false
  var body: some View {
    Button {
      clip?.copy(entry)
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      state.app?.overlay.collapse()
      state.app?.overlay.showLiveNotice(.text("Copiado", symbol: "doc.on.doc.fill"), seconds: 1.6)
    } label: {
      HStack(spacing: 8) {
        Text(entry.text.replacingOccurrences(of: "\n", with: " ⏎ "))
          .font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        Text(entry.date.formatted(.relative(presentation: .numeric)))
          .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0.05)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(entry.text.prefix(400) + (entry.sourceApp.map { "\n\nDe \($0)" } ?? ""))
  }
}

// MARK: Herramientas rápidas

struct AwakeButton: View {
  let quick: QuickTools
  var body: some View {
    ToolButton(symbol: quick.isAwake ? "cup.and.saucer.fill" : "cup.and.saucer", tint: .orange,
               title: quick.isAwake ? "Despierto" : "Mantener despierto", subtitle: subtitle) {
      if quick.isAwake { quick.stopAwake() } else { quick.setAwake(minutes: nil) }
    }
  }
  var subtitle: String {
    if let u = quick.awakeUntil { return "Hasta las " + u.formatted(date: .omitted, time: .shortened) }
    return quick.isAwake ? "Toca para apagarlo" : "No se duerme ni apaga la pantalla"
  }
}

struct TimerButton: View {
  let quick: QuickTools
  @State private var hover = false
  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        Circle().fill(Color.mint.opacity(0.22))
        Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.mint)
      }
      .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 3) {
        if quick.timerRunning {
          TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(QuickTools.clock(quick.timerRemaining(at: ctx.date))).font(.system(size: 12, weight: .semibold).monospacedDigit())
          }
          Button("Detener") { quick.stopTimer() }.buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.mint)
        } else {
          Text("Temporizador · min").font(.system(size: 12, weight: .semibold)).lineLimit(1)
          HStack(spacing: 3) {
            ForEach([5, 15, 25, 50], id: \.self) { m in
              Button { quick.startTimer(minutes: Double(m)) } label: {
                Text("\(m)")
                  .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                  .fixedSize()
                  .frame(minWidth: 18)
                  .padding(.horizontal, 4).padding(.vertical, 1.5)
                  .background(Capsule().fill(Color.white.opacity(0.12)))
              }
              .buttonStyle(.plain)
            }
          }
          .fixedSize()
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(height: 54)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0.055)))
    .onHover { h in withAnimation(.spring(response: 0.25)) { hover = h } }
  }
}

/// Recibe archivos soltados sobre la isla abierta.
struct ShelfDropDelegate: DropDelegate {
  let state: OverlayState
  func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
  func dropEntered(info: DropInfo) {
    withAnimation(.spring(response: 0.3)) {
      state.page = .shelf
      state.dropTargeting = true
    }
  }
  func dropExited(info: DropInfo) { withAnimation(.spring(response: 0.3)) { state.dropTargeting = false } }
  func performDrop(info: DropInfo) -> Bool {
    let providers = info.itemProviders(for: [.fileURL])
    for p in providers {
      _ = p.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            withAnimation(.spring(response: 0.35)) { state.app?.shelf.add([url]) }
          }
        }
      }
    }
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    withAnimation(.spring(response: 0.3)) { state.dropTargeting = false }
    return !providers.isEmpty
  }
}
