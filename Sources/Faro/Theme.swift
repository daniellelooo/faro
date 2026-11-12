import AppKit
import SwiftUI

/// Paleta de Faro: violeta de marca con un acento coral para la voz.
enum Theme {
  static let violet = Color(red: 0.43, green: 0.34, blue: 0.81)
  static let coral = Color(red: 1.0, green: 0.48, blue: 0.35)
  static let ink = Color(nsColor: .labelColor)
  static let brandGradient = LinearGradient(colors: [violet, Color(red: 0.62, green: 0.36, blue: 0.86), coral],
    startPoint: .topLeading, endPoint: .bottomTrailing)
  static let cardBackground = Color(nsColor: .controlBackgroundColor)
  static let subtleBorder = Color.primary.opacity(0.08)
}

/// Superficie de tarjeta con borde suave.
struct Card<Content: View>: View {
  var padding: CGFloat = 18
  @ViewBuilder var content: Content
  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardBackground))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.subtleBorder))
  }
}

/// Tecla dibujada, para explicar el atajo.
struct Keycap: View {
  let label: String
  var size: CGFloat = 44
  var body: some View {
    Text(label)
      .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
      .foregroundStyle(.primary)
      .frame(width: size * 1.15, height: size)
      .background(
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
          .fill(Color(nsColor: .windowBackgroundColor))
          .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 2)
      )
      .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(Theme.subtleBorder))
  }
}

/// Ícono de una app por su bundle id (con caché).
@MainActor
enum AppIcons {
  private static var cache: [String: NSImage] = [:]
  static func icon(_ bundleID: String?, appName: String? = nil) -> NSImage {
    guard let bundleID else {
      // Dictados viejos sin bundle id: se busca la app por su nombre.
      if let appName {
        if let i = cache["nombre:" + appName] { return i }
        let candidates = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
          .map { "\($0)/\(appName).app" }
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
          let i = NSWorkspace.shared.icon(forFile: path)
          cache["nombre:" + appName] = i
          return i
        }
      }
      return NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
    if let i = cache[bundleID] { return i }
    let image: NSImage
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      image = NSWorkspace.shared.icon(forFile: url.path)
    } else {
      image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }
    cache[bundleID] = image
    return image
  }
}

/// Distribuye elementos en filas que se acomodan al ancho (para las palabras del diccionario).
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 600
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x + size.width > width, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: width, height: y + rowHeight)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX, x > bounds.minX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
