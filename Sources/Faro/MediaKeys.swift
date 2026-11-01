import AppKit
import CoreGraphics

/// Teclas de volumen y brillo: llegan como eventos de sistema (NX_SYSDEFINED, tipo 14, subtipo 8).
/// Si Faro las atiende, el evento se descarta y macOS no muestra su indicador; la isla muestra el nivel.
@MainActor
final class MediaKeyMonitor {
  enum Key: Int { case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

  /// Devuelve true si la tecla se atendió (y hay que tragarse el evento).
  var onKey: (_ key: Key, _ fine: Bool) -> Bool = { _, _ in false }
  var enabled = true
  private var tap: CFMachPort?
  private var watchdog: Timer?
  /// Teclas cuya pulsación se tragó: su soltada también se traga, para no dejar a macOS con media tecla.
  private var swallowed: Set<Int> = []

  func start() -> Bool {
    let mask = CGEventMask(1 << 14)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
      callback: { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
      }, userInfo: refcon)
    else { return false }
    self.tap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        if let tap = self?.tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
      }
    }
    return true
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard enabled, type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
      return Unmanaged.passUnretained(event)
    }
    let code = (ns.data1 & 0xFFFF_0000) >> 16
    let state = (ns.data1 & 0xFF00) >> 8
    let isDown = state == 0x0A
    guard let key = Key(rawValue: code) else { return Unmanaged.passUnretained(event) }
    if !isDown {
      return swallowed.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
    }
    // Con Comando o Control la tecla sigue a macOS (por ejemplo, para abrir Sonido o Pantallas).
    let flags = ns.modifierFlags
    if flags.contains(.command) || flags.contains(.control) { return Unmanaged.passUnretained(event) }
    let fine = flags.contains(.option) && flags.contains(.shift)
    if onKey(key, fine) {
      swallowed.insert(code)
      return nil
    }
    return Unmanaged.passUnretained(event)
  }
}
