import AppKit
import FaroCore
import Observation
import SwiftUI

@MainActor @Observable
final class CopilotState {
  var answers: [CopilotAnswer] = []
  var listening = false
  var notes: [String] = []
}

/// Panel flotante con las respuestas del copiloto. Queda fuera de lo que se comparte en pantalla
/// (`sharingType = .none`), no toma el foco y se puede arrastrar a cualquier esquina.
@MainActor
final class CopilotPanel {
  let state = CopilotState()
  private let panel: NSPanel

  init() {
    panel = CopilotNSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 340),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.sharingType = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = NSHostingView(rootView: CopilotView(state: state) { [weak self] in self?.hide() })
  }

  var windowNumber: Int { panel.windowNumber }

  func show() {
    if !panel.isVisible, let screen = NSScreen.main {
      let f = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 16, y: f.maxY - panel.frame.height - 16))
    }
    panel.orderFrontRegardless()
  }

  func hide() { panel.orderOut(nil) }

  func reset(notes: [String]) {
    state.answers = []
    state.notes = notes
    state.listening = true
  }

  func add(_ a: CopilotAnswer) {
    withAnimation(.spring(duration: 0.3)) { state.answers.insert(a, at: 0) }
    if state.answers.count > 6 { state.answers.removeLast(state.answers.count - 6) }
    show()
  }
}

private final class CopilotNSPanel: NSPanel {
  override var canBecomeKey: Bool { false }
}

struct CopilotView: View {
  let state: CopilotState
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Circle().fill(state.listening ? Color.green : Color.secondary).frame(width: 7, height: 7)
        Text(state.notes.isEmpty ? "Copiloto" : "Copiloto · \(state.notes.joined(separator: ", "))")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
          .buttonStyle(.plain).foregroundStyle(.secondary).help("Ocultar (sigue escuchando)")
      }
      if state.answers.isEmpty {
        Text("Escuchando. Cuando pregunten algo del sistema, la respuesta aparece aquí.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(state.answers.enumerated()), id: \.element.id) { i, a in
              AnswerCard(answer: a, latest: i == 0)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(width: 400, height: 340, alignment: .topLeading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
  }
}

private struct AnswerCard: View {
  let answer: CopilotAnswer
  let latest: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(answer.question).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        if !answer.inNotes {
          Text("No está en la ficha").font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.25), in: Capsule())
        }
      }
      Text(answer.answer)
        .font(latest ? .system(size: 15, weight: .medium) : .callout)
        .foregroundStyle(latest ? .primary : .secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(latest ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
