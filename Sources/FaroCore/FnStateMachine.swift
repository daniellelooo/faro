import Foundation

/// Lógica de la tecla Fn, separada del teclado para poder probarla:
/// - mantener ≥ 0,5 s = dictar mientras se sostiene;
/// - toque < 0,5 s: se espera 0,5 s por un segundo toque; si llega, manos libres; si no, se descarta;
/// - en manos libres, el siguiente toque termina;
/// - Fn + otra tecla en el primer segundo = la persona quería un atajo, se cancela.
public struct FnStateMachine: Sendable {
  public enum Action: Equatable, Sendable { case startRecording, stopAndProcess, cancelRecording, enterHandsFree }
  enum State: Equatable { case idle, holding(Double), tapPending(Double), handsFree, finishing, cancelledHold }

  public static let holdThreshold = 0.5
  public static let doubleTapWindow = 0.5
  public static let comboCancelWindow = 1.0

  var state: State = .idle
  public init() {}

  public var isHandsFree: Bool { state == .handsFree }

  public mutating func press(at t: Double) -> [Action] {
    switch state {
    case .idle, .finishing, .cancelledHold:
      state = .holding(t)
      return [.startRecording]
    case .tapPending(let releasedAt) where t - releasedAt <= Self.doubleTapWindow:
      state = .handsFree
      return [.enterHandsFree]
    case .tapPending:
      state = .holding(t)
      return [.cancelRecording, .startRecording]
    case .handsFree:
      state = .finishing
      return [.stopAndProcess]
    case .holding:
      return []
    }
  }

  public mutating func release(at t: Double) -> [Action] {
    switch state {
    case .holding(let p):
      if t - p >= Self.holdThreshold {
        state = .idle
        return [.stopAndProcess]
      }
      state = .tapPending(t)
      return []
    case .finishing, .cancelledHold:
      state = .idle
      return []
    default:
      return []
    }
  }

  public mutating func tick(at t: Double) -> [Action] {
    if case .tapPending(let r) = state, t - r > Self.doubleTapWindow {
      state = .idle
      return [.cancelRecording]
    }
    return []
  }

  public mutating func otherKey(at t: Double) -> [Action] {
    if case .holding(let p) = state, t - p < Self.comboCancelWindow {
      state = .cancelledHold
      return [.cancelRecording]
    }
    return []
  }
}
