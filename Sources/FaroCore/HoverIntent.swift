import CoreGraphics
import Foundation

/// Decide si el puntero sobre la isla quiere abrirla, separado del mouse para poder probarlo:
/// - la espera empieza de nuevo cada vez que el puntero se mueve (se abre solo si queda quieto);
/// - un temblor de pocos puntos no cuenta como movimiento;
/// - un clic o un arrastre en la zona bloquean la apertura hasta que el puntero salga de ella.
public struct HoverIntent: Sendable {
  public enum Action: Equatable, Sendable { case none, restartWait, cancelWait }

  /// Cuánto tiene que quedarse quieto el puntero para abrir la isla.
  public static let dwell = 0.4
  public static let jitterTolerance: CGFloat = 3

  public private(set) var blocked = false
  private var anchor: CGPoint?
  public init() {}

  public mutating func moved(to p: CGPoint, inside: Bool) -> Action {
    guard inside else {
      blocked = false
      anchor = nil
      return .cancelWait
    }
    if blocked { return .cancelWait }
    if let a = anchor, hypot(p.x - a.x, p.y - a.y) <= Self.jitterTolerance { return .none }
    anchor = p
    return .restartWait
  }

  /// Clic o arrastre en la zona: la persona estaba usando lo que hay debajo.
  public mutating func block() {
    blocked = true
    anchor = nil
  }

  /// La isla se abrió: la siguiente vez se empieza de cero.
  public mutating func reset() {
    blocked = false
    anchor = nil
  }
}
