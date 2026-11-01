import AppKit
import FaroCore

/// Pega con Cmd+V usando un portapapeles con datos diferidos: cuando la app de destino pide el texto sabemos que el
/// pegado llegó. Después se restaura el portapapeles completo.
@MainActor
enum PasteInjector {
  enum Outcome { case pasted, notRequested, noPermission }

  private final class Provider: NSObject, NSPasteboardItemDataProvider {
    let text: String
    var requested = false
    init(_ text: String) { self.text = text }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
      requested = true
      item.setString(text, forType: type)
    }
  }

  static func paste(_ text: String, into pid: pid_t) async -> Outcome {
    let pb = NSPasteboard.general
    guard AXIsProcessTrusted() else {
      pb.clearContents()
      pb.setString(text, forType: .string)
      return .noPermission
    }
    // Volver a la app donde empezó el dictado si la persona cambió de ventana.
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
      let app = NSRunningApplication(processIdentifier: pid)
    {
      app.activate()
      try? await Task.sleep(for: .milliseconds(150))
    }
    // Esperar a que se suelten Fn y los modificadores, para que el Cmd+V llegue limpio.
    for _ in 0..<15 {
      let flags = CGEventSource.flagsState(.combinedSessionState)
      if flags.intersection([.maskSecondaryFn, .maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
    let snapshot = PasteboardSnapshot.capture(pb)
    let provider = Provider(text)
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.string])
    pb.clearContents()
    pb.writeObjects([item])

    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cgAnnotatedSessionEventTap)
    up?.post(tap: .cgAnnotatedSessionEventTap)

    for _ in 0..<40 where !provider.requested {
      try? await Task.sleep(for: .milliseconds(20))
    }
    let requested = provider.requested
    if requested {
      try? await Task.sleep(for: .milliseconds(500))
      snapshot.restore(to: pb)
    } else {
      // Nadie pidió el texto: se deja copiado para pegarlo a mano.
      pb.clearContents()
      pb.setString(text, forType: .string)
    }
    return requested ? .pasted : .notRequested
  }
}
