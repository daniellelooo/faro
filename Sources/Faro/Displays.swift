import AppKit
import CoreGraphics
import FaroCore
import IOKit
import Observation

/// Brillo de cada pantalla por separado:
/// - la del Mac con DisplayServices (privado, el mismo que usan las teclas de brillo);
/// - un monitor externo por DDC/CI (órdenes por el cable); si no responde, oscureciendo la imagen por software.
@MainActor @Observable
final class DisplayController {
  enum Method: String { case native, ddc, software }

  struct Display: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
    var method: Method
    var brightness: Float
  }

  private(set) var displays: [Display] = []
  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored private var avServices: [CGDirectDisplayID: AnyObject] = [:]
  @ObservationIgnored private var ddcPending: [CGDirectDisplayID: Task<Void, Never>] = [:]

  init() {
    refresh()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  // MARK: Pantallas

  func refresh() {
    var list: [Display] = []
    let externals = Self.externalAVServices()
    var externalIndex = 0
    for screen in NSScreen.screens {
      guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
      if CGDisplayIsBuiltin(id) != 0 {
        list.append(Display(id: id, name: "Pantalla del Mac", isBuiltIn: true, method: .native, brightness: Self.nativeBrightness(id) ?? 1))
      } else {
        // Con un solo monitor externo la relación pantalla ↔ servicio es directa.
        let service = externalIndex < externals.count ? externals[externalIndex] : nil
        externalIndex += 1
        if let service { avServices[id] = service }
        let forcedDDC = defaults.bool(forKey: key("ddc", screen.localizedName))
        let method: Method = forcedDDC ? .ddc : .software
        let level = defaults.object(forKey: key("brillo", screen.localizedName)) as? Float ?? 1
        list.append(Display(id: id, name: screen.localizedName, isBuiltIn: false, method: method, brightness: level))
        if method == .software && level < 1 { Self.applyGamma(id, level) }
        // Preguntarle al monitor por DDC tarda (y muchos por HDMI no contestan): se hace fuera del hilo principal.
        if !forcedDDC, let service { probe(id, service) }
      }
    }
    displays = list
  }

  private func probe(_ id: CGDirectDisplayID, _ service: AnyObject) {
    nonisolated(unsafe) let svc = service
    Task.detached {
      guard let read = Self.ddcRead(svc) else { return }
      await MainActor.run {
        guard let i = self.displays.firstIndex(where: { $0.id == id }) else { return }
        CGDisplayRestoreColorSyncSettings()
        self.displays[i].method = .ddc
        self.displays[i].brightness = Float(read.current) / Float(max(read.max, 1))
      }
    }
  }

  /// La pantalla donde está el puntero (a ella van las teclas de brillo).
  var displayUnderPointer: Display? {
    let m = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }),
      let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    else { return displays.first }
    return displays.first { $0.id == id } ?? displays.first
  }

  func setBrightness(_ value: Float, for id: CGDirectDisplayID) {
    guard let i = displays.firstIndex(where: { $0.id == id }) else { return }
    let v = min(1, max(0, value))
    displays[i].brightness = v
    let d = displays[i]
    switch d.method {
    case .native:
      Self.setNativeBrightness(id, v)
    case .ddc:
      // Las órdenes DDC son lentas (decenas de ms): se agrupan y solo se manda la última.
      ddcPending[id]?.cancel()
      let service = avServices[id]
      ddcPending[id] = Task.detached { [weak self] in
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled, let service else { return }
        Self.ddcWrite(service, value: UInt16((v * 100).rounded()))
        _ = self
      }
      defaults.set(v, forKey: key("brillo", d.name))
    case .software:
      Self.applyGamma(id, v)
      defaults.set(v, forKey: key("brillo", d.name))
    }
  }

  /// Para monitores que no contestan las lecturas DDC pero sí obedecen las órdenes (pasa mucho por HDMI).
  func setUsesDDC(_ on: Bool, for id: CGDirectDisplayID) {
    guard let i = displays.firstIndex(where: { $0.id == id }), !displays[i].isBuiltIn else { return }
    defaults.set(on, forKey: key("ddc", displays[i].name))
    if on {
      CGDisplayRestoreColorSyncSettings()
      displays[i].method = .ddc
    } else {
      displays[i].method = .software
    }
    setBrightness(displays[i].brightness, for: id)
  }

  /// Al salir se devuelve la imagen a la normalidad (el oscurecido por software no debe quedar puesto sin Faro).
  func restoreOnQuit() { CGDisplayRestoreColorSyncSettings() }

  private func key(_ kind: String, _ name: String) -> String { "pantalla.\(kind).\(name)" }

  // MARK: DisplayServices (pantalla del Mac)

  private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
  private nonisolated(unsafe) static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

  static func nativeBrightness(_ id: CGDirectDisplayID) -> Float? {
    guard let sym = dlsym(displayServices, "DisplayServicesGetBrightness") else { return nil }
    var v: Float = 0
    return unsafeBitCast(sym, to: GetFn.self)(id, &v) == 0 ? v : nil
  }

  static func setNativeBrightness(_ id: CGDirectDisplayID, _ v: Float) {
    guard let sym = dlsym(displayServices, "DisplayServicesSetBrightness") else { return }
    _ = unsafeBitCast(sym, to: SetFn.self)(id, v)
  }

  // MARK: DDC por IOAVService (Apple Silicon)

  private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
  private typealias I2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
  private nonisolated(unsafe) static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

  static func externalAVServices() -> [AnyObject] {
    guard let createSym = dlsym(iokit, "IOAVServiceCreateWithService") else { return [] }
    let create = unsafeBitCast(createSym, to: CreateFn.self)
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    var out: [AnyObject] = []
    while case let s = IOIteratorNext(iter), s != 0 {
      defer { IOObjectRelease(s) }
      let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
      if loc == "External", let svc = create(kCFAllocatorDefault, s)?.takeRetainedValue() { out.append(svc) }
    }
    return out
  }

  nonisolated static func ddcWrite(_ service: AnyObject, value: UInt16) {
    guard let sym = dlsym(iokit, "IOAVServiceWriteI2C") else { return }
    let write = unsafeBitCast(sym, to: I2CFn.self)
    var packet = DDC.setPacket(vcp: DDC.brightness, value: value)
    // Algunos monitores pierden la primera orden: se manda dos veces.
    for _ in 0..<2 {
      _ = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
      usleep(20_000)
    }
  }

  nonisolated static func ddcRead(_ service: AnyObject) -> (current: Int, max: Int)? {
    guard let w = dlsym(iokit, "IOAVServiceWriteI2C"), let r = dlsym(iokit, "IOAVServiceReadI2C") else { return nil }
    let write = unsafeBitCast(w, to: I2CFn.self), read = unsafeBitCast(r, to: I2CFn.self)
    var packet = DDC.getPacket(vcp: DDC.brightness)
    for _ in 0..<2 {
      _ = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
      usleep(50_000)
      var reply = [UInt8](repeating: 0, count: 11)
      guard reply.withUnsafeMutableBytes({ read(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }) == 0 else { continue }
      if let v = DDC.parseReply(reply, vcp: DDC.brightness) { return v }
    }
    return nil
  }

  // MARK: Oscurecer por software (curva de gamma)

  static func applyGamma(_ id: CGDirectDisplayID, _ level: Float) {
    // Nunca del todo negro: con 0 la pantalla quedaría inutilizable.
    let m = 0.08 + 0.92 * level
    CGSetDisplayTransferByFormula(id, 0, m, 1, 0, m, 1, 0, m, 1)
  }
}
