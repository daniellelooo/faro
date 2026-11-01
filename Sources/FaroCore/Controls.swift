import Foundation

/// Mensajes DDC/CI para controlar monitores externos por el cable (VESA MCCS), como hace MonitorControl.
/// Se escriben al chip 0x37 en la dirección 0x51 a través de IOAVService.
public enum DDC {
  public static let brightness: UInt8 = 0x10
  public static let contrast: UInt8 = 0x12

  /// Orden "poner valor" de un código VCP: [0x84, 0x03, vcp, alto, bajo, checksum].
  public static func setPacket(vcp: UInt8, value: UInt16) -> [UInt8] {
    var p: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
    p[5] = checksum(p[0..<5])
    return p
  }

  /// Orden "leer valor": [0x82, 0x01, vcp, checksum]. La respuesta llega con `parseReply`.
  public static func getPacket(vcp: UInt8) -> [UInt8] {
    var p: [UInt8] = [0x82, 0x01, vcp, 0]
    p[3] = checksum(p[0..<3])
    return p
  }

  /// El checksum DDC incluye la dirección de destino (0x6E) y la de origen (0x51).
  static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 { bytes.reduce(0x6E ^ 0x51) { $0 ^ $1 } }

  /// Respuesta a "leer valor": [0x6E, 0x88, 0x02, resultado, vcp, tipo, máxAlto, máxBajo, actAlto, actBajo, checksum].
  /// nil si no es una respuesta válida para ese código (muchos monitores por HDMI devuelven basura o su EDID).
  public static func parseReply(_ r: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
    guard r.count >= 11, r[1] == 0x88, r[2] == 0x02, r[3] == 0x00, r[4] == vcp else { return nil }
    let chk = r[0..<10].reduce(0x50) { $0 ^ $1 }
    guard chk == r[10] else { return nil }
    let max = Int(r[6]) << 8 | Int(r[7]), current = Int(r[8]) << 8 | Int(r[9])
    guard max > 0, current <= max else { return nil }
    return (current, max)
  }
}

/// Pasos de volumen y brillo con las teclas: 16 pasos como macOS, o 64 con Opción+Mayúsculas.
public enum LevelSteps {
  public static func next(_ value: Float, up: Bool, fine: Bool = false) -> Float {
    let steps: Float = fine ? 64 : 16
    // Se redondea al paso más cercano para que, partiendo de cualquier valor, se llegue justo a 0 y a 1.
    let index = (value * steps).rounded()
    let moved = up ? index + 1 : index - 1
    return min(1, max(0, moved / steps))
  }
}

/// Ganancia por app para el mezclador de volumen: se multiplica el audio y un limitador suave evita que sature
/// cuando se sube por encima del 100 %.
public enum GainProcessor {
  public static func apply(_ gain: Float, to samples: UnsafeMutableBufferPointer<Float>) {
    guard gain != 1 else { return }
    for i in samples.indices { samples[i] = process(samples[i], gain: gain) }
  }

  @inline(__always)
  public static func process(_ sample: Float, gain: Float) -> Float {
    let v = sample * gain
    return gain > 1 ? softClip(v) : v
  }

  /// Lineal hasta 0,8 y luego se dobla suave hacia 1 (sin el chasquido de cortar en seco).
  public static func softClip(_ x: Float) -> Float {
    let a = abs(x)
    guard a > 0.8 else { return x }
    let over = a - 0.8
    let shaped = 0.8 + 0.2 * (over / (over + 0.2))
    return x < 0 ? -shaped : shaped
  }
}

/// Qué scroll invierte Faro. El "desplazamiento natural" de macOS es uno solo para la rueda del mouse y el
/// trackpad; aquí van por separado. La rueda manda eventos por pasos y el trackpad (o un Magic Mouse), continuos.
public struct ScrollInversion: Equatable, Sendable {
  public var mouse: Bool
  public var trackpad: Bool

  public init(mouse: Bool = false, trackpad: Bool = false) {
    self.mouse = mouse
    self.trackpad = trackpad
  }

  public var isActive: Bool { mouse || trackpad }

  public func inverts(continuous: Bool) -> Bool { continuous ? trackpad : mouse }
}

/// Páginas de video reconocidas por el título de la pestaña (el que el navegador pone en su ventana).
public enum VideoSites {
  static let markers = ["youtube", "netflix", "twitch", "vimeo", "disney+", "prime video", "max", "hbo",
    "crunchyroll", "stremio", "plex", "apple tv", "dailymotion", "kick"]

  public static func isWatching(title: String) -> Bool {
    // El sitio va al final del título ("Video - YouTube", "Serie | Netflix"); se mira solo ese último trozo
    // para que una página que solo menciona YouTube no cuente.
    let last = title.lowercased()
      .components(separatedBy: CharacterSet(charactersIn: "-|–—·:"))
      .last?.trimmingCharacters(in: .whitespaces) ?? ""
    // YouTube pone delante las notificaciones sin leer: "(3) YouTube".
    let site = last.replacingOccurrences(of: #"^\(\d+\+?\)\s*"#, with: "", options: .regularExpression)
    return markers.contains(site)
  }
}

/// Scroll por pasos para juegos: cada muesca de la rueda es exactamente un paso (un espacio del inventario en
/// Minecraft). En una rueda común (el ATK A9 por su receptor «NK Mouse Dongle») macOS acelera el scroll: una muesca
/// lenta llega como fracción de línea y una rápida como varias, así que el inventario no avanza o salta espacios; aquí
/// cada evento vale exactamente una línea. Una rueda con scroll suave (MX Master con Logi Options+) o el trackpad
/// mandan ráfagas continuas con inercia: la inercia se descarta, cada ráfaga nueva da un paso apenas empieza y, si
/// sigue girando en la misma ráfaga, otro paso por cada `pixelsPerStep` acumulados.
public struct ScrollStepper: Sendable {
  /// Pausa sin eventos que separa una ráfaga (una muesca) de la siguiente.
  public var burstGap: TimeInterval = 0.12
  public var pixelsPerStep: Double = 40
  private var lastTime: TimeInterval = -1
  private var lastDirection = 0
  private var accumulated = 0.0

  public init() {}

  /// Pasos para este evento: -1, 0 (descartarlo) o 1. `delta` es el desplazamiento vertical del evento, en puntos
  /// si es continuo y en líneas si es de la rueda clásica.
  public mutating func steps(delta: Double, continuous: Bool, momentum: Bool, time: TimeInterval) -> Int {
    if momentum { return 0 }
    guard delta != 0 else { return 0 }
    let direction = delta > 0 ? 1 : -1
    // La rueda clásica ya manda un evento por muesca: solo se le quita la aceleración.
    guard continuous else { return direction }
    defer {
      lastTime = time
      lastDirection = direction
    }
    if lastTime < 0 || time - lastTime > burstGap || direction != lastDirection {
      accumulated = 0
      return direction
    }
    accumulated += abs(delta)
    guard accumulated >= pixelsPerStep else { return 0 }
    accumulated -= pixelsPerStep
    return direction
  }
}
