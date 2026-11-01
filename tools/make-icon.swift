// Ícono de Faro: el faro en blanco saliendo desde el borde de abajo, con franjas horizontales y la linterna
// como destello con halo y conos de luz. El ícono es la variante 31; las demás quedan de referencia.
// Uso: swift tools/make-icon.swift Resources/AppIcon-1024.png [variante]   |   ... hoja|hoja2|hoja3 salida.png
import AppKit
import CoreGraphics

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: cs, components: [CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255, a])!
}
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
  CGGradient(colorsSpace: cs, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}
let ink = hex(0xEEF4FF)

/// Hoja afilada de punta a punta; ancho máximo `w` en la fracción `t` del recorrido. `bend` curva la hoja.
func blade(_ a: CGPoint, _ b: CGPoint, width w: CGFloat, at t: CGFloat = 0.5, bend: CGFloat = 0) -> CGPath {
  let dx = b.x - a.x, dy = b.y - a.y
  let len = hypot(dx, dy)
  let nx = -dy / len, ny = dx / len
  let m = CGPoint(x: a.x + dx * t + nx * bend, y: a.y + dy * t + ny * bend)
  let p = CGMutablePath()
  p.move(to: a)
  p.addCurve(to: b, control1: CGPoint(x: m.x + nx * w - dx * 0.2, y: m.y + ny * w - dy * 0.2),
             control2: CGPoint(x: m.x + nx * w + dx * 0.2, y: m.y + ny * w + dy * 0.2))
  p.addCurve(to: a, control1: CGPoint(x: m.x - nx * w + dx * 0.2, y: m.y - ny * w + dy * 0.2),
             control2: CGPoint(x: m.x - nx * w - dx * 0.2, y: m.y - ny * w - dy * 0.2))
  p.closeSubpath()
  return p
}

func sparkle(_ c: CGPoint, _ r: CGFloat, waist: CGFloat, rotation: CGFloat = 0) -> CGPath {
  let p = CGMutablePath()
  for i in 0..<4 {
    let a = rotation + CGFloat(i) * .pi / 2
    let tip = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    let ctrl = CGPoint(x: c.x + cos(a + .pi / 4) * waist, y: c.y + sin(a + .pi / 4) * waist)
    let next = CGPoint(x: c.x + cos(a + .pi / 2) * r, y: c.y + sin(a + .pi / 2) * r)
    if i == 0 { p.move(to: tip) }
    p.addQuadCurve(to: next, control: ctrl)
  }
  p.closeSubpath()
  return p
}

/// Torre desde abajo (y=40, fuera del ícono) hasta `top`. `curve` > 0 hace los lados cóncavos (se abre abajo).
func tower(cx: CGFloat, top: CGFloat, baseHalf: CGFloat, topHalf: CGFloat, curve: CGFloat = 0) -> CGPath {
  let p = CGMutablePath()
  let base: CGFloat = 40
  p.move(to: CGPoint(x: cx - baseHalf, y: base))
  p.addLine(to: CGPoint(x: cx + baseHalf, y: base))
  p.addQuadCurve(to: CGPoint(x: cx + topHalf, y: top),
    control: CGPoint(x: cx + (baseHalf + topHalf) / 2 - curve, y: (base + top) / 2))
  p.addLine(to: CGPoint(x: cx - topHalf, y: top))
  p.addQuadCurve(to: CGPoint(x: cx - baseHalf, y: base),
    control: CGPoint(x: cx - (baseHalf + topHalf) / 2 + curve, y: (base + top) / 2))
  p.closeSubpath()
  return p
}

func draw(_ v: Int, in ctx: CGContext) {
  func fill(_ p: CGPath) { ctx.addPath(p); ctx.setFillColor(ink); ctx.fillPath() }
  /// Recorta (en el color del fondo, es decir, transparente al fondo) quitando esa forma de lo que se dibuje después.
  func cutting(_ cut: CGPath, _ body: () -> Void) {
    ctx.saveGState()
    let clip = CGMutablePath()
    clip.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    clip.addPath(cut)
    ctx.addPath(clip)
    ctx.clip(using: .evenOdd)
    body()
    ctx.restoreGState()
  }
  let rr = { (r: CGRect, k: CGFloat) in CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil) }

  switch v {
  case 21, 22, 23, 31, 32, 33:
    // Opción 2 de cerca: torre grande recortada abajo, franjas por corte, destello con brillo y haces de luz.
    let top: CGFloat = 540
    let cuts = CGMutablePath()
    switch v {
    case 31:
      // Franjas horizontales, como un faro de verdad.
      for y in [CGFloat(190), CGFloat(380)] { cuts.addRect(CGRect(x: 200, y: y, width: 624, height: 36)) }
    case 32:
      // Una sola franja, ancha, cerca de la linterna.
      cuts.addRect(CGRect(x: 200, y: 380, width: 624, height: 34))
    case 33:
      // Torre lisa con dos ventanas angostas y una puerta.
      cuts.addRoundedRect(in: CGRect(x: 498, y: 420, width: 28, height: 64), cornerWidth: 14, cornerHeight: 14)
      cuts.addRoundedRect(in: CGRect(x: 498, y: 280, width: 28, height: 64), cornerWidth: 14, cornerHeight: 14)
      let door = CGMutablePath()
      door.addRoundedRect(in: CGRect(x: 478, y: 60, width: 68, height: 130), cornerWidth: 34, cornerHeight: 34)
      cuts.addPath(door)
    default:
      for y in [CGFloat(150), CGFloat(350)] {
        cuts.move(to: CGPoint(x: 200, y: y)); cuts.addLine(to: CGPoint(x: 824, y: y + 96))
        cuts.addLine(to: CGPoint(x: 824, y: y + 134)); cuts.addLine(to: CGPoint(x: 200, y: y + 38)); cuts.closeSubpath()
      }
    }
    cutting(cuts) { fill(tower(cx: 512, top: top, baseHalf: 220, topHalf: 120)) }
    fill(rr(CGRect(x: 512 - 158, y: top + 14, width: 316, height: 28), 14))
    let lamp = CGPoint(x: 512, y: top + 172)
    // Brillo: halo grande y suave alrededor de la linterna.
    let haloAlpha: CGFloat = v == 23 ? 0.55 : 0.4
    ctx.drawRadialGradient(gradient([(hex(0xEEF4FF, haloAlpha), 0), (hex(0xBFD6FF, haloAlpha * 0.35), 0.35), (hex(0xBFD6FF, 0), 1)]),
      startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: 380, options: [])
    if v == 21 {
      // Haces sólidos y afilados.
      fill(blade(CGPoint(x: lamp.x + 80, y: lamp.y), CGPoint(x: 1000, y: lamp.y + 90), width: 22, at: 0.1))
      fill(blade(CGPoint(x: lamp.x - 80, y: lamp.y), CGPoint(x: 24, y: lamp.y + 90), width: 22, at: 0.1))
    } else {
      // Haces como luz: cuña que se abre y se desvanece, con un núcleo fino y brillante.
      for dir in [CGFloat(1), CGFloat(-1)] {
        let wedge = CGMutablePath()
        wedge.move(to: CGPoint(x: lamp.x + dir * 60, y: lamp.y - 14))
        wedge.addLine(to: CGPoint(x: lamp.x + dir * 560, y: lamp.y - 40))
        wedge.addLine(to: CGPoint(x: lamp.x + dir * 560, y: lamp.y + 230))
        wedge.addLine(to: CGPoint(x: lamp.x + dir * 60, y: lamp.y + 14))
        wedge.closeSubpath()
        ctx.saveGState()
        ctx.addPath(wedge)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(hex(0xEEF4FF, v == 23 ? 0.75 : 0.6), 0), (hex(0xEEF4FF, 0.18), 0.55), (hex(0xEEF4FF, 0), 1)]),
          start: CGPoint(x: lamp.x + dir * 60, y: lamp.y), end: CGPoint(x: lamp.x + dir * 520, y: lamp.y), options: [])
        ctx.restoreGState()
        fill(blade(CGPoint(x: lamp.x + dir * 70, y: lamp.y), CGPoint(x: lamp.x + dir * 520, y: lamp.y + 104), width: 7, at: 0.08))
      }
    }
    fill(sparkle(lamp, v == 23 ? 150 : 128, waist: 22))
    if v == 23 {
      // Destello secundario girado: luz que irradia.
      ctx.saveGState()
      ctx.setAlpha(0.5)
      fill(sparkle(lamp, 92, waist: 10, rotation: .pi / 4))
      ctx.restoreGState()
    }

  case 1:
    // Clásico: torre recta, linterna con ventanas, cúpula y un haz largo a la derecha.
    let top: CGFloat = 560
    fill(tower(cx: 512, top: top, baseHalf: 128, topHalf: 72))
    fill(rr(CGRect(x: 512 - 104, y: top + 10, width: 208, height: 20), 10))
    let lamp = CGRect(x: 512 - 58, y: top + 42, width: 116, height: 92)
    cutting({ let p = CGMutablePath(); for x in [lamp.minX + 34, lamp.maxX - 42] { p.addRect(CGRect(x: x, y: lamp.minY + 14, width: 8, height: lamp.height - 28)) }; return p }()) {
      fill(rr(lamp, 12))
    }
    let dome = CGMutablePath()
    dome.addArc(center: CGPoint(x: 512, y: lamp.maxY + 10), radius: 62, startAngle: 0, endAngle: .pi, clockwise: false)
    dome.closeSubpath()
    fill(dome)
    fill(blade(CGPoint(x: 512, y: lamp.maxY + 66), CGPoint(x: 512, y: lamp.maxY + 128), width: 5))
    fill(blade(CGPoint(x: lamp.maxX + 24, y: lamp.midY), CGPoint(x: 940, y: lamp.midY + 150), width: 26, at: 0.12))
    fill(blade(CGPoint(x: lamp.minX - 24, y: lamp.midY), CGPoint(x: 150, y: lamp.midY + 80), width: 14, at: 0.12))

  case 2:
    // Rayado: cortes diagonales en la torre y la linterna como un destello con haces simétricos.
    let top: CGFloat = 600
    let cuts = CGMutablePath()
    for y in [CGFloat(250), CGFloat(420)] {
      cuts.move(to: CGPoint(x: 300, y: y)); cuts.addLine(to: CGPoint(x: 724, y: y + 70))
      cuts.addLine(to: CGPoint(x: 724, y: y + 96)); cuts.addLine(to: CGPoint(x: 300, y: y + 26)); cuts.closeSubpath()
    }
    cutting(cuts) { fill(tower(cx: 512, top: top, baseHalf: 120, topHalf: 64)) }
    fill(rr(CGRect(x: 512 - 92, y: top + 10, width: 184, height: 18), 9))
    let lamp = CGPoint(x: 512, y: top + 104)
    fill(sparkle(lamp, 78, waist: 14))
    fill(blade(CGPoint(x: lamp.x + 56, y: lamp.y), CGPoint(x: 950, y: lamp.y + 70), width: 13, at: 0.1))
    fill(blade(CGPoint(x: lamp.x - 56, y: lamp.y), CGPoint(x: 74, y: lamp.y + 70), width: 13, at: 0.1))

  case 3:
    // Elegante: torre de lados cóncavos que se abre abajo, destello por linterna y un haz largo que se afina.
    let top: CGFloat = 600
    fill(tower(cx: 512, top: top, baseHalf: 190, topHalf: 46, curve: 92))
    fill(rr(CGRect(x: 512 - 74, y: top + 8, width: 148, height: 16), 8))
    let lamp = CGPoint(x: 512, y: top + 92)
    fill(sparkle(lamp, 64, waist: 12))
    fill(blade(CGPoint(x: lamp.x + 46, y: lamp.y + 4), CGPoint(x: 940, y: lamp.y + 196), width: 22, at: 0.1, bend: -18))
    fill(blade(CGPoint(x: lamp.x - 46, y: lamp.y + 4), CGPoint(x: 220, y: lamp.y + 120), width: 10, at: 0.1, bend: 8))

  case 4:
    // Haz que corta: un haz fino atraviesa la linterna en diagonal y la parte con un aire.
    let top: CGFloat = 540
    fill(tower(cx: 512, top: top, baseHalf: 124, topHalf: 72))
    fill(rr(CGRect(x: 512 - 100, y: top + 10, width: 200, height: 20), 10))
    let head = CGMutablePath()
    head.addRoundedRect(in: CGRect(x: 512 - 60, y: top + 42, width: 120, height: 100), cornerWidth: 12, cornerHeight: 12)
    let dome = CGMutablePath()
    head.addArc(center: CGPoint(x: 512, y: top + 152), radius: 64, startAngle: 0, endAngle: .pi, clockwise: false)
    head.closeSubpath()
    _ = dome
    head.addPath(blade(CGPoint(x: 512, y: top + 212), CGPoint(x: 512, y: top + 262), width: 5))
    cutting(blade(CGPoint(x: 140, y: 520), CGPoint(x: 900, y: 860), width: 26)) {
      ctx.addPath(head); ctx.setFillColor(ink); ctx.fillPath()
    }
    fill(blade(CGPoint(x: 170, y: 533), CGPoint(x: 880, y: 851), width: 7))

  default:
    // Cono de luz: torre a la izquierda; de la linterna sale un cono que se abre hacia la esquina.
    let cx: CGFloat = 380, top: CGFloat = 580
    fill(tower(cx: cx, top: top, baseHalf: 112, topHalf: 62))
    fill(rr(CGRect(x: cx - 88, y: top + 10, width: 176, height: 18), 9))
    let lamp = CGRect(x: cx - 52, y: top + 40, width: 104, height: 86)
    fill(rr(lamp, 12))
    let dome = CGMutablePath()
    dome.addArc(center: CGPoint(x: cx, y: lamp.maxY + 8), radius: 58, startAngle: 0, endAngle: .pi, clockwise: false)
    dome.closeSubpath()
    fill(dome)
    let cone = CGMutablePath()
    cone.move(to: CGPoint(x: lamp.maxX + 22, y: lamp.midY + 6))
    cone.addQuadCurve(to: CGPoint(x: 1000, y: 820), control: CGPoint(x: 700, y: 700))
    cone.addLine(to: CGPoint(x: 1000, y: 1000))
    cone.addQuadCurve(to: CGPoint(x: lamp.maxX + 22, y: lamp.midY + 22), control: CGPoint(x: 640, y: 820))
    cone.closeSubpath()
    ctx.saveGState()
    ctx.addPath(cone)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(ink, 0), (hex(0xEEF4FF, 0.15), 1)]),
      start: CGPoint(x: lamp.maxX, y: lamp.midY), end: CGPoint(x: 960, y: 920), options: [])
    ctx.restoreGState()

  }
}

func icon(_ v: Int) -> CGImage {
  let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let shape = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 32, color: hex(0x000000, 0.45))
  ctx.addPath(shape)
  ctx.setFillColor(hex(0x05070D))
  ctx.fillPath()
  ctx.restoreGState()
  ctx.addPath(shape)
  ctx.clip()
  ctx.drawLinearGradient(gradient([(hex(0x05070D), 0), (hex(0x0F1A2B), 0.45), (hex(0x3A5273), 1)]),
    start: CGPoint(x: 160, y: 900), end: CGPoint(x: 880, y: 110), options: [])
  // Todo lo blanco se dibuja recortado a la forma del ícono: el faro "sale" del borde de abajo.
  draw(v, in: ctx)
  return ctx.makeImage()!
}

func save(_ img: CGImage, _ path: String) {
  try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = Array(CommandLine.arguments.dropFirst())
let iconMode = args.first?.hasSuffix(".png") ?? true
let arg = iconMode ? (args.count > 1 ? args[1] : "31") : args[0]
let out = iconMode ? (args.first ?? "AppIcon-1024.png") : args[1]
if arg.hasPrefix("hoja") {
  let ids = arg == "hoja" ? [1, 2, 3, 4, 5] : (arg == "hoja2" ? [21, 22, 23] : [31, 32, 33])
  let n = ids.count, cell: CGFloat = 512, pad: CGFloat = 24
  let w = CGFloat(n) * cell + CGFloat(n + 1) * pad, h = cell + 2 * pad + 40
  let sheet = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  sheet.setFillColor(hex(0x1C1C1E))
  sheet.fill(CGRect(x: 0, y: 0, width: w, height: h))
  for i in 1...n {
    sheet.draw(icon(ids[i - 1]), in: CGRect(x: pad + CGFloat(i - 1) * (cell + pad), y: pad + 40, width: cell, height: cell))
    let label = NSAttributedString(string: "\(i)", attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white])
    let gc = NSGraphicsContext(cgContext: sheet, flipped: false)
    NSGraphicsContext.current = gc
    label.draw(at: CGPoint(x: pad + CGFloat(i - 1) * (cell + pad) + cell / 2 - 8, y: 14))
  }
  save(sheet.makeImage()!, out)
} else {
  save(icon(Int(arg) ?? 31), out)
}
