import Foundation
import Testing
@testable import FaroCore

@Suite struct DDCTests {
  @Test func paqueteParaPonerBrillo() {
    // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32 = 0x9A
    #expect(DDC.setPacket(vcp: DDC.brightness, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
  }

  @Test func paqueteParaLeerBrillo() {
    #expect(DDC.getPacket(vcp: DDC.brightness) == [0x82, 0x01, 0x10, 0xAC])
  }

  @Test func leeUnaRespuestaValida() {
    var r: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2D, 0]
    r[10] = r[0..<10].reduce(0x50) { $0 ^ $1 }
    let v = DDC.parseReply(r, vcp: DDC.brightness)
    #expect(v?.current == 45)
    #expect(v?.max == 100)
  }

  @Test func rechazaLaBasuraDeUnMonitorPorHDMI() {
    // Lo que devolvió un monitor LED real: parte de su EDID ("MONITOR\n ").
    let edid: [UInt8] = [0x4d, 0x4f, 0x4e, 0x49, 0x54, 0x4f, 0x52, 0x0a, 0x20, 0x00, 0x00]
    #expect(DDC.parseReply(edid, vcp: DDC.brightness) == nil)
  }
}

@Suite struct LevelStepsTests {
  @Test func dieciseisPasos() {
    #expect(LevelSteps.next(0.5, up: true) == 0.5625)
    #expect(LevelSteps.next(0.5, up: false) == 0.4375)
    #expect(LevelSteps.next(1, up: true) == 1)
    #expect(LevelSteps.next(0.03, up: false) == 0)
  }

  @Test func pasosFinos() {
    #expect(LevelSteps.next(0.5, up: true, fine: true) == 0.515625)
  }

  @Test func desdeUnValorRaroSeAlineaAlPaso() {
    #expect(LevelSteps.next(0.51, up: true) == 0.5625)
  }
}

@Suite struct GainTests {
  @Test func bajarVolumenEsLineal() {
    var s: [Float] = [0.5, -0.5, 1]
    s.withUnsafeMutableBufferPointer { GainProcessor.apply(0.5, to: $0) }
    #expect(s == [0.25, -0.25, 0.5])
  }

  @Test func subirNoPasaDeUno() {
    var s: [Float] = [0.9, -0.95, 0.3]
    s.withUnsafeMutableBufferPointer { GainProcessor.apply(2, to: $0) }
    #expect(s.allSatisfy { abs($0) < 1 })
    #expect(abs(s[2] - 0.6) < 0.0001)
  }
}

@Suite struct ScrollInversionTests {
  @Test func soloElMouseDejaElTrackpadIgual() {
    let s = ScrollInversion(mouse: true, trackpad: false)
    #expect(s.inverts(continuous: false))
    #expect(!s.inverts(continuous: true))
    #expect(s.isActive)
  }

  @Test func soloElTrackpadDejaLaRuedaIgual() {
    let s = ScrollInversion(mouse: false, trackpad: true)
    #expect(!s.inverts(continuous: false))
    #expect(s.inverts(continuous: true))
  }

  @Test func apagadoNoTocaNada() {
    let s = ScrollInversion()
    #expect(!s.isActive)
    #expect(!s.inverts(continuous: false))
    #expect(!s.inverts(continuous: true))
  }
}

@Suite struct VideoSitesTests {
  @Test func reconoceVideosPorElTituloDeLaPestana() {
    #expect(VideoSites.isWatching(title: "Lo-fi para estudiar - YouTube"))
    #expect(VideoSites.isWatching(title: "(3) Clase 4 - YouTube"))
    #expect(VideoSites.isWatching(title: "Stranger Things | Netflix"))
    #expect(VideoSites.isWatching(title: "ibai - Twitch"))
    // La portada con el número de notificaciones delante, como la muestra Arc.
    #expect(VideoSites.isWatching(title: "(1) YouTube"))
  }

  @Test func noConfundeOtrasPaginas() {
    #expect(!VideoSites.isWatching(title: "Pull requests · daniellelooo/faro"))
    #expect(!VideoSites.isWatching(title: "Notion"))
    #expect(!VideoSites.isWatching(title: ""))
  }
}

@Suite struct ScrollStepperTests {
  @Test func laRuedaClasicaDaUnPasoPorMuescaSinAceleracion() {
    var s = ScrollStepper()
    #expect(s.steps(delta: 7, continuous: false, momentum: false, time: 0) == 1)
    #expect(s.steps(delta: -3, continuous: false, momentum: false, time: 0.01) == -1)
  }

  @Test func unaRafagaSuaveEsUnSoloPaso() {
    var s = ScrollStepper()
    // Una muesca con scroll suave: varios eventos pequeños seguidos y después la inercia.
    let pasos = [3.0, 6, 8, 5, 3].enumerated().map { s.steps(delta: $1, continuous: true, momentum: false, time: Double($0) * 0.016) }
    #expect(pasos.reduce(0, +) == 1)
    #expect(s.steps(delta: 4, continuous: true, momentum: true, time: 0.1) == 0)
  }

  @Test func dosMuescasSeparadasSonDosPasos() {
    var s = ScrollStepper()
    #expect(s.steps(delta: 5, continuous: true, momentum: false, time: 0) == 1)
    #expect(s.steps(delta: 5, continuous: true, momentum: false, time: 0.3) == 1)
  }

  @Test func cambiarDeDireccionDaPasoEnSeguida() {
    var s = ScrollStepper()
    #expect(s.steps(delta: 5, continuous: true, momentum: false, time: 0) == 1)
    #expect(s.steps(delta: -5, continuous: true, momentum: false, time: 0.02) == -1)
  }

  @Test func girarRapidoSigueAvanzandoPeroSinSaltarse() {
    var s = ScrollStepper()
    // 100 puntos seguidos en una ráfaga: el paso inicial y dos más (cada 40).
    let pasos = (0..<10).map { s.steps(delta: 10, continuous: true, momentum: false, time: Double($0) * 0.016) }
    #expect(pasos.reduce(0, +) == 3)
  }
}
