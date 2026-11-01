import AppKit
import CoreGraphics
import FaroCore

/// Escucha la tecla Fn/Globe con un event tap activo y la pasa por `FnStateMachine`.
/// Se traga los eventos de Fn (63) y Globe (179) para que macOS no abra el selector de emojis.
@MainActor
final class HotkeyMonitor {
  var onAction: (FnStateMachine.Action) -> Void = { _ in }
  private(set) var machine = FnStateMachine()
  private var tap: CFMachPort?
  private var fnDown = false
  private var ticker: Timer?
  private var watchdog: Timer?
  static let fnKey: Int64 = 63
  static let globeKey: Int64 = 179

  var isHandsFree: Bool { machine.isHandsFree }

  func start() -> Bool {
    let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
      callback: { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
      }, userInfo: refcon)
    else { return false }
    self.tap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.emit(self?.machine.tick(at: Self.now()) ?? []) }
    }
    // macOS desactiva el tap si tarda o tras ciertos eventos: se revisa y se reactiva.
    watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        if let tap = self?.tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
      }
    }
    return true
  }

  static func now() -> Double { ProcessInfo.processInfo.systemUptime }

  private func emit(_ actions: [FnStateMachine.Action]) {
    for a in actions { onAction(a) }
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .keyDown || type == .keyUp {
      if keycode == Self.globeKey { return nil }
      if type == .keyDown && fnDown { emit(machine.otherKey(at: Self.now())) }
      return Unmanaged.passUnretained(event)
    }
    // flagsChanged: solo nos importa la tecla Fn (las flechas también levantan maskSecondaryFn).
    guard keycode == Self.fnKey else { return Unmanaged.passUnretained(event) }
    let isDown = event.flags.contains(.maskSecondaryFn)
    if isDown && !fnDown {
      fnDown = true
      emit(machine.press(at: Self.now()))
    } else if !isDown && fnDown {
      fnDown = false
      emit(machine.release(at: Self.now()))
    }
    return nil
  }
}
