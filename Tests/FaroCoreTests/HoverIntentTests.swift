import CoreGraphics
import Testing
@testable import FaroCore

@Suite struct HoverIntentTests {
  private let p = CGPoint(x: 100, y: 10)

  @Test func entrarEmpiezaLaEspera() {
    var i = HoverIntent()
    #expect(i.moved(to: p, inside: true) == .restartWait)
  }
  @Test func moverseReiniciaLaEspera() {
    var i = HoverIntent()
    _ = i.moved(to: p, inside: true)
    #expect(i.moved(to: CGPoint(x: 120, y: 10), inside: true) == .restartWait)
  }
  @Test func unTemblorNoReiniciaLaEspera() {
    var i = HoverIntent()
    _ = i.moved(to: p, inside: true)
    #expect(i.moved(to: CGPoint(x: 102, y: 11), inside: true) == .none)
  }
  @Test func elTemblorSeMideDesdeElPuntoInicial() {
    // Muchos movimientos chiquitos seguidos suman un movimiento de verdad.
    var i = HoverIntent()
    _ = i.moved(to: p, inside: true)
    _ = i.moved(to: CGPoint(x: 102, y: 10), inside: true)
    #expect(i.moved(to: CGPoint(x: 104, y: 10), inside: true) == .restartWait)
  }
  @Test func salirCancelaLaEspera() {
    var i = HoverIntent()
    _ = i.moved(to: p, inside: true)
    #expect(i.moved(to: p, inside: false) == .cancelWait)
    #expect(i.moved(to: p, inside: true) == .restartWait)
  }
  @Test func unClicBloqueaHastaSalir() {
    var i = HoverIntent()
    _ = i.moved(to: p, inside: true)
    i.block()
    #expect(i.blocked)
    #expect(i.moved(to: CGPoint(x: 150, y: 10), inside: true) == .cancelWait)
    #expect(i.moved(to: p, inside: false) == .cancelWait)
    #expect(!i.blocked)
    #expect(i.moved(to: p, inside: true) == .restartWait)
  }
  @Test func alAbrirseEmpiezaDeCero() {
    var i = HoverIntent()
    _ = i.moved(to: p, inside: true)
    i.reset()
    #expect(i.moved(to: p, inside: true) == .restartWait)
  }
}
