import Foundation
import Testing
@testable import FaroCore

@Suite struct InsertionAdjusterTests {
  @Test func aMitadDeFraseVaEnMinusculaYConEspacio() {
    #expect(InsertionAdjuster.adjust("La reunión es mañana.", before: "Te cuento que", after: "") == " la reunión es mañana.")
  }
  @Test func despuesDePuntoQuedaEnMayuscula() {
    #expect(InsertionAdjuster.adjust("la reunión es mañana.", before: "Hola. ", after: "") == "La reunión es mañana.")
  }
  @Test func campoVacioQuedaIgual() {
    #expect(InsertionAdjuster.adjust("Hola, Juan.", before: "", after: "") == "Hola, Juan.")
  }
  @Test func noBajaNombresPropiosDelDiccionario() {
    #expect(InsertionAdjuster.adjust("Supabase está caído.", before: "y además", after: "", properNouns: ["Supabase"]) == " Supabase está caído.")
  }
  @Test func siSigueTextoQuitaElPuntoFinalYAgregaEspacio() {
    #expect(InsertionAdjuster.adjust("El martes.", before: "Nos vemos ", after: "a las 3") == "el martes ")
  }
  @Test func listasNoSeTocan() {
    let list = "- Uno\n- Dos"
    #expect(InsertionAdjuster.adjust(list, before: "Pendientes:\n", after: "") == list)
  }
}

@Suite struct SegmenterTests {
  func voice(_ s: Double) -> [Float] { (0..<Int(s * 16000)).map { Float(sin(Double($0) * 0.05)) * 0.3 } }
  func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16000)) }

  @Test func cortaEnUnaPausaDespuesDeTresSegundos() {
    let audio = voice(3.5) + silence(0.6) + voice(1)
    let cut = SpeechSegmenter.nextCut(in: audio, from: 0, sampleRate: 16000)
    #expect(cut != nil)
    #expect(cut! > 3 * 16000 && cut! < Int(4.2 * 16000))
  }
  @Test func noCortaSiLaVozEsCorta() {
    let audio = voice(1.5) + silence(0.6) + voice(1)
    #expect(SpeechSegmenter.nextCut(in: audio, from: 0, sampleRate: 16000) == nil)
  }
  @Test func noCortaSinPausa() {
    #expect(SpeechSegmenter.nextCut(in: voice(6), from: 0, sampleRate: 16000) == nil)
  }
  @Test func cortaAlLimiteDeVeinticincoSegundosAunqueNoHayaPausa() {
    let cut = SpeechSegmenter.nextCut(in: voice(27), from: 0, sampleRate: 16000)
    #expect(cut == 25 * 16000)
  }
}

@Suite struct ContextPromptTests {
  @Test func elPromptIncluyeElContextoYLaReglaDeNoContinuarlo() {
    let ctx = ScreenContext(appName: "Slack", windowTitle: "#general", textBefore: "¿Quién revisa el PR de Datavia?", textAfter: "", selectedText: nil)
    let s = CleanupPrompt.system(tone: .casual, dictionary: .default)
    let u = CleanupPrompt.user(raw: "yo lo reviso", context: ctx)
    #expect(u.contains("<contexto>"))
    #expect(u.contains("Datavia"))
    #expect(u.contains("<transcripcion>\nyo lo reviso\n</transcripcion>"))
    #expect(s.lowercased().contains("contexto"))
  }
  @Test func elContextoSeRecortaA500Caracteres() {
    let long = String(repeating: "a", count: 2000)
    let ctx = ScreenContext(appName: "X", windowTitle: nil, textBefore: long, textAfter: long, selectedText: nil)
    #expect(ctx.trimmed.textBefore!.count == 500)
    #expect(ctx.trimmed.textAfter!.count == 500)
  }
}

@Suite struct FnStateMachineTests {
  @Test func mantenerGrabaYSoltarProcesa() {
    var m = FnStateMachine()
    #expect(m.press(at: 0) == [.startRecording])
    #expect(m.release(at: 1.2) == [.stopAndProcess])
  }
  @Test func toqueSueltoSeDescartaTrasLaVentana() {
    var m = FnStateMachine()
    _ = m.press(at: 0)
    #expect(m.release(at: 0.2) == [])
    #expect(m.tick(at: 0.75) == [.cancelRecording])
  }
  @Test func dobleToqueEntraEnManosLibresYOtroToqueProcesa() {
    var m = FnStateMachine()
    _ = m.press(at: 0)
    _ = m.release(at: 0.15)
    #expect(m.press(at: 0.4) == [.enterHandsFree])
    #expect(m.release(at: 0.5) == [])
    #expect(m.tick(at: 5) == [])
    #expect(m.press(at: 8) == [.stopAndProcess])
    #expect(m.release(at: 8.1) == [])
  }
  @Test func fnConOtraTeclaAlPrincipioCancela() {
    var m = FnStateMachine()
    _ = m.press(at: 0)
    #expect(m.otherKey(at: 0.5) == [.cancelRecording])
    #expect(m.release(at: 0.8) == [])
  }
  @Test func otraTeclaDespuesDeUnSegundoNoCancela() {
    var m = FnStateMachine()
    _ = m.press(at: 0)
    #expect(m.otherKey(at: 1.5) == [])
    #expect(m.release(at: 2) == [.stopAndProcess])
  }
}
