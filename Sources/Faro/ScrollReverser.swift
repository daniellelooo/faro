import CoreGraphics
import FaroCore
import Foundation

/// Invierte el scroll de la rueda del mouse, del trackpad o de los dos, y en juegos lo pasa a un paso por muesca,
/// con un event tap sobre los eventos de scroll. El tap solo existe mientras alguna opción está prendida.
@MainActor
final class ScrollReverser {
  var inversion = ScrollInversion() {
    didSet { updateTap() }
  }
  /// Con un juego al frente, cada muesca de la rueda es un paso (sin scroll suave ni inercia).
  var steppedInGames = false {
    didSet { updateTap() }
  }
  /// Lo actualiza la revisión de cada segundo de la app al frente (mirar eso en cada evento sería caro).
  var gameInFront = false
  private var stepper = ScrollStepper()

  private func updateTap() { inversion.isActive || steppedInGames ? start() : stop() }
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?

  private func start() {
    guard tap == nil else { return }
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
      callback: { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let reverser = Unmanaged<ScrollReverser>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated { reverser.handle(type: type, event: event) }
      }, userInfo: refcon)
    else { return }
    self.tap = tap
    source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func stop() {
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    CFMachPortInvalidate(tap)
    self.tap = nil
    source = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    if steppedInGames && gameInFront { return stepped(event, continuous: continuous) }
    guard inversion.inverts(continuous: continuous) else { return Unmanaged.passUnretained(event) }
    // Se leen todos los campos antes de escribir: poner el delta en líneas recalcula los otros dos.
    let delta = (event.getIntegerValueField(.scrollWheelEventDeltaAxis1), event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    let fixed = (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
    let point = (event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta.0)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta.1)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed.0)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed.1)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point.0)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point.1)
    return Unmanaged.passUnretained(event)
  }

  /// Cambia el evento por uno de rueda clásica de exactamente una línea, o lo descarta (inercia, resto de la ráfaga).
  private func stepped(_ event: CGEvent, continuous: Bool) -> Unmanaged<CGEvent>? {
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
    var delta = continuous
      ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
      : event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    if delta == 0 { delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) }
    if inversion.inverts(continuous: continuous) { delta = -delta }
    let steps = stepper.steps(delta: delta, continuous: continuous, momentum: momentum, time: ProcessInfo.processInfo.systemUptime)
    // Solo scroll horizontal (o nada): pasa tal cual.
    if delta == 0 && !momentum { return Unmanaged.passUnretained(event) }
    guard steps != 0,
      let line = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(steps), wheel2: 0, wheel3: 0)
    else { return nil }
    line.location = event.location
    line.flags = event.flags
    return Unmanaged.passRetained(line)
  }
}
