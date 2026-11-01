import SwiftUI

/// Marca de Faro para la isla: el destello de la linterna con sus dos haces, como en el ícono de la app.
struct FaroMark: View {
  var size: CGFloat = 13
  var body: some View {
    Canvas { ctx, sz in
      let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
      let r = sz.height * 0.5
      // Haces: dos cuñas finas que se apagan hacia afuera.
      for dir in [CGFloat(-1), 1] {
        var beam = Path()
        beam.move(to: CGPoint(x: c.x + dir * r * 0.45, y: c.y - r * 0.12))
        beam.addLine(to: CGPoint(x: c.x + dir * sz.width / 2, y: c.y - r * 0.34))
        beam.addLine(to: CGPoint(x: c.x + dir * sz.width / 2, y: c.y + r * 0.08))
        beam.addLine(to: CGPoint(x: c.x + dir * r * 0.45, y: c.y + r * 0.12))
        beam.closeSubpath()
        ctx.fill(beam, with: .linearGradient(Gradient(colors: [.white.opacity(0.9), .white.opacity(0)]),
          startPoint: c, endPoint: CGPoint(x: c.x + dir * sz.width / 2, y: c.y)))
      }
      ctx.fill(Sparkle.path(center: c, radius: r, waist: r * 0.2), with: .color(.white))
    }
    .frame(width: size * 1.9, height: size)
    .shadow(color: .white.opacity(0.35), radius: 3)
  }
}

enum Sparkle {
  /// Destello de cuatro puntas con lados cóncavos.
  static func path(center c: CGPoint, radius r: CGFloat, waist: CGFloat, rotation: CGFloat = 0) -> Path {
    var p = Path()
    for i in 0..<4 {
      let a = rotation + CGFloat(i) * .pi / 2 - .pi / 2
      let tip = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
      let ctrl = CGPoint(x: c.x + cos(a + .pi / 4) * waist, y: c.y + sin(a + .pi / 4) * waist)
      let next = CGPoint(x: c.x + cos(a + .pi / 2) * r, y: c.y + sin(a + .pi / 2) * r)
      if i == 0 { p.move(to: tip) }
      p.addQuadCurve(to: next, control: ctrl)
    }
    p.closeSubpath()
    return p
  }
}

/// Claude te espera: una mano que se balancea suave, como llamando.
struct ClaudeWaiting: View {
  var size: CGFloat = 12
  @State private var wave = false
  var body: some View {
    Image(systemName: "hand.raised.fill")
      .font(.system(size: size, weight: .semibold))
      .foregroundStyle(.orange)
      .rotationEffect(.degrees(wave ? 14 : -10), anchor: .bottom)
      .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: wave)
      .onAppear { wave = true }
  }
}

/// Check que se dibuja al aparecer (aviso de "Claude terminó").
struct DrawnCheck: View {
  var color: Color = .claude
  @State private var progress: CGFloat = 0
  var body: some View {
    ZStack {
      Circle().fill(color.opacity(0.18))
      Circle().trim(from: 0, to: progress).stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
      CheckShape().trim(from: 0, to: progress)
        .stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        .frame(width: 16, height: 12)
    }
    .frame(width: 40, height: 40)
    .onAppear { withAnimation(.easeOut(duration: 0.55).delay(0.12)) { progress = 1 } }
  }
}

struct CheckShape: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
    p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    return p
  }
}
