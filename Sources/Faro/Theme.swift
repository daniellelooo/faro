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

/// Superficie de tarjeta: algo translúcida sobre el fondo de la ventana, con borde fino y sombra apenas visible.
struct Card<Content: View>: View {
  var padding: CGFloat = 18
  @ViewBuilder var content: Content
  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(CardBackground())
  }
}

struct CardBackground: View {
  var radius: CGFloat = 12
  var body: some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.075), lineWidth: 1))
      .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
  }
}

/// Ícono en un cuadro de color, como los de Ajustes del Sistema.
struct IconTile: View {
  let symbol: String
  let tint: Color
  var size: CGFloat = 28
  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      .fill(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
      .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
      .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
      .frame(width: size, height: size)
  }
}

/// Título de una sección dentro de una pantalla, con algo opcional a la derecha.
struct SectionTitle<Trailing: View>: View {
  let title: String
  var subtitle: String? = nil
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
      }
      Spacer(minLength: 8)
      trailing
    }
  }
}

extension SectionTitle where Trailing == EmptyView {
  init(_ title: String, subtitle: String? = nil) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}

/// Fondo translúcido de la ventana (deja ver, desenfocado, lo que hay detrás).
struct WindowMaterial: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .underWindowBackground
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = material
    v.blendingMode = .behindWindow
    v.state = .followsWindowActiveState
    return v
  }
  func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
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
