import AppKit
import FaroCore
import Observation
import SwiftUI

/// Bloquea el teclado (y las teclas de función y multimedia) para poder limpiarlo. Se sale con un clic o a los 60 s.
@MainActor @Observable
final class KeyboardCleaner {
  var active = false
  var remaining = 60
  private var tap: CFMachPort?
  private var windows: [NSWindow] = []
  private var timer: Timer?

  func start() {
    guard !active else { return }
    let types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14 /* teclas de sistema y multimedia */]
    let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1) }
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
      callback: { _, _, _, _ in nil }, userInfo: nil)
    guard let tap else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    active = true
    remaining = 60
    for screen in NSScreen.screens {
      let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
      w.level = .screenSaver
      w.backgroundColor = .clear
      w.isOpaque = false
      w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      w.contentView = NSHostingView(rootView: KeyboardCleaningView(cleaner: self))
      w.setFrame(screen.frame, display: true)
      w.orderFrontRegardless()
      windows.append(w)
    }
    NSApp.activate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.remaining -= 1
        if self.remaining <= 0 { self.stop() }
      }
    }
  }

  func stop() {
    timer?.invalidate()
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    tap = nil
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    active = false
  }
}

struct KeyboardCleaningView: View {
  let cleaner: KeyboardCleaner
  var body: some View {
    ZStack {
      Color.black.opacity(0.88).ignoresSafeArea()
      VStack(spacing: 18) {
        Image(systemName: "keyboard").font(.system(size: 64, weight: .light)).foregroundStyle(.white)
        Text("Limpia tu teclado").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
        Text("Todas las teclas están bloqueadas, incluidas las de brillo, volumen y música.")
          .font(.title3).foregroundStyle(.white.opacity(0.75))
        Text("\(cleaner.remaining) s").font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        Button("Terminar limpieza") { cleaner.stop() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(Theme.violet)
      }
    }
  }
}

/// Paquetes de Homebrew con actualización pendiente, y su actualización en segundo plano.
@MainActor @Observable
final class BrewService {
  var available = FileManager.default.isExecutableFile(atPath: BrewOutdated.brew)
  var outdated: [BrewPackage] = []
  var checking = false
  var upgrading: Set<String> = []
  var lastChecked: Date?
  var lastError: String?
  @ObservationIgnored var onUpgradeFinished: ((String) -> Void)?

  func check(update: Bool = true) {
    guard available, !checking else { return }
    checking = true
    lastError = nil
    Task.detached(priority: .utility) {
      if update { _ = Self.run(["update", "--quiet"]) }
      let (status, out) = Self.run(["outdated", "--json=v2"])
      let items = (try? BrewOutdated.parse(out)) ?? []
      await MainActor.run {
        self.outdated = items
        self.checking = false
        self.lastChecked = Date()
        if status != 0 && items.isEmpty { self.lastError = "No se pudo consultar Homebrew." }
      }
    }
  }

  func upgrade(_ packages: [BrewPackage]) {
    let names = packages.map(\.name)
    guard !names.isEmpty else { return }
    upgrading.formUnion(names)
    let casks = packages.filter(\.isCask).map(\.name)
    let formulae = packages.filter { !$0.isCask }.map(\.name)
    Task.detached(priority: .utility) {
      var failed = false
      if !formulae.isEmpty { failed = Self.run(["upgrade"] + formulae).0 != 0 || failed }
      if !casks.isEmpty { failed = Self.run(["upgrade", "--cask"] + casks).0 != 0 || failed }
      let didFail = failed
      await MainActor.run {
        self.upgrading.subtract(names)
        let text = didFail
          ? "Homebrew: hubo un error al actualizar"
          : (names.count == 1 ? "Homebrew actualizó \(names[0])" : "Homebrew actualizó \(names.count) paquetes")
        self.onUpgradeFinished?(text)
        self.check(update: false)
      }
    }
  }

  nonisolated static func run(_ args: [String]) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: BrewOutdated.brew)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["HOMEBREW_NO_ENV_HINTS"] = "1"
    env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (-1, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
  }
}
