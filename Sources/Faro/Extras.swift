import AppKit
import FaroCore
import Observation
import SwiftUI

/// Historial del portapapeles (solo texto, solo en memoria; nunca lo que marcan los gestores de contraseñas).
@MainActor @Observable
final class ClipboardService {
  private(set) var history = ClipboardHistory(limit: 30)
  @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
  @ObservationIgnored private var timer: Timer?

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  private func poll() {
    let pb = NSPasteboard.general
    guard pb.changeCount != lastChange else { return }
    lastChange = pb.changeCount
    let types = (pb.types ?? []).map(\.rawValue)
    guard ClipboardHistory.shouldRecord(types: types), let text = pb.string(forType: .string) else { return }
    history.add(text, sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName)
  }

  /// Vuelve a poner un texto en el portapapeles (sube al primer lugar del historial).
  func copy(_ entry: ClipboardHistory.Entry) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(entry.text, forType: .string)
    lastChange = pb.changeCount
    history.add(entry.text, sourceApp: entry.sourceApp)
  }

  func remove(_ id: UUID) { history.remove(id) }
  func clear() { history.clear() }
}

/// Bandeja del notch: archivos que se dejan ahí para soltarlos después en otro lado.
@MainActor @Observable
final class ShelfService {
  @ObservationIgnored private let store = ShelfStore()
  private(set) var items: [ShelfItem] = []

  init() { items = store.items }

  func add(_ urls: [URL]) {
    store.add(urls)
    items = store.items
  }

  func remove(_ id: UUID) {
    store.remove(id)
    items = store.items
  }

  func clear() {
    store.clear()
    items = store.items
  }
}

/// Herramientas rápidas: mantener el Mac despierto, temporizador y cuentagotas de color.
@MainActor @Observable
final class QuickTools {
  // Despierto
  private(set) var awakeUntil: Date?
  private(set) var awakeIndefinitely = false
  @ObservationIgnored private var awakeActivity: NSObjectProtocol?
  /// Guardado aparte (y no calculado del token, que no se observa) para que la interfaz se entere al apagarlo.
  private(set) var isAwake = false

  // Temporizador
  private(set) var timerEnd: Date?
  private(set) var timerDuration: TimeInterval = 0
  @ObservationIgnored private var tick: Timer?
  @ObservationIgnored var onTimerFinished: (() -> Void)?
  @ObservationIgnored var onColorPicked: ((String) -> Void)?

  var timerRunning: Bool { timerEnd != nil }
  func timerRemaining(at now: Date = Date()) -> TimeInterval { max(0, (timerEnd ?? now).timeIntervalSince(now)) }

  func setAwake(minutes: Int?) {
    stopAwake()
    awakeActivity = ProcessInfo.processInfo.beginActivity(
      options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated], reason: "Faro: mantener despierto")
    if let minutes {
      awakeUntil = Date().addingTimeInterval(Double(minutes) * 60)
    } else {
      awakeIndefinitely = true
    }
    isAwake = true
    ensureTick()
  }

  func stopAwake() {
    if let a = awakeActivity { ProcessInfo.processInfo.endActivity(a) }
    awakeActivity = nil
    awakeUntil = nil
    awakeIndefinitely = false
    isAwake = false
  }

  func startTimer(minutes: Double) {
    timerDuration = minutes * 60
    timerEnd = Date().addingTimeInterval(timerDuration)
    ensureTick()
  }

  func stopTimer() {
    timerEnd = nil
    timerDuration = 0
  }

  private func ensureTick() {
    guard tick == nil else { return }
    tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
  }

  private func check() {
    let now = Date()
    if let end = timerEnd, now >= end {
      stopTimer()
      NSSound(named: "Glass")?.play()
      onTimerFinished?()
    }
    if let until = awakeUntil, now >= until { stopAwake() }
    if timerEnd == nil && awakeActivity == nil {
      tick?.invalidate()
      tick = nil
    }
  }

  /// Cuentagotas del sistema: el color elegido se copia en hexadecimal.
  func pickColor() {
    NSColorSampler().show { [weak self] color in
      guard let color, let rgb = color.usingColorSpace(.sRGB) else { return }
      let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
        Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(hex, forType: .string)
      MainActor.assumeIsolated { self?.onColorPicked?(hex) }
    }
  }

  static func clock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
  }
}
