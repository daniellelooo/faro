import AVFoundation
import AppKit
import CoreGraphics

/// Estado de los permisos de macOS que necesita Faro. Los concede el usuario en Ajustes del Sistema.
@MainActor
enum Permissions {
  static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
  static var accessibility: Bool { AXIsProcessTrusted() }
  static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
  /// Para el audio del Mac en videollamadas (ScreenCaptureKit).
  static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }
  static func requestScreenCapture() { CGRequestScreenCaptureAccess() }

  static func requestMicrophone() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  /// Muestra el aviso del sistema para Accesibilidad (sin activarlo: eso lo hace la persona).
  static func promptAccessibility() {
    let key = "AXTrustedCheckOptionPrompt" as CFString
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func open(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }
}
