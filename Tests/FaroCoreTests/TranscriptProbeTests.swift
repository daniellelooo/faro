import Foundation
import Testing
@testable import FaroCore

@Suite struct TranscriptProbeTests {
  func line(_ type: String, _ ts: String, stop: String? = nil, extra: String = "") -> String {
    let msg = stop.map { #","message":{"role":"assistant","stop_reason":""# + $0 + #""}"# } ?? ""
    return #"{"type":""# + type + #"","isSidechain":false,"cwd":"/x/faro","timestamp":""# + ts + #"""# + msg + extra + "}"
  }

  @Test func ignoraLosDatosDeControlDeLaAppDeEscritorio() {
    let tail = [line("assistant", "2026-10-26T16:40:00Z", stop: "end_turn"),
                #"{"type":"last-prompt"}"#, #"{"type":"cost-state"}"#, #"{"type":"atis-latch"}"#].joined(separator: "\n")
    let s = TranscriptProbe.status(tail: tail, sessionID: "a")
    #expect(s?.finished == true)
    #expect(s?.cwd == "/x/faro")
  }

  @Test func unaHerramientaEnCursoEsTrabajo() {
    let tail = [line("assistant", "2026-10-26T16:40:00Z", stop: "tool_use"), line("user", "2026-10-26T16:40:05Z")].joined(separator: "\n")
    let s = TranscriptProbe.status(tail: tail, sessionID: "a")
    #expect(s?.finished == false)
    #expect(s?.lastMessageAt == Date(timeIntervalSince1970: 1_793_032_805))
  }

  @Test func unaSesionSinHooksApareceTrabajandoYAvisaAlTerminar() {
    var board = ClaudeActivityBoard()
    let t0 = Date(timeIntervalSince1970: 1_793_032_800)
    board.apply(TranscriptProbe.Status(sessionID: "s", cwd: "/x/kivo", lastMessageAt: t0, finished: false), now: t0.addingTimeInterval(10))
    #expect(board.sessions["s"]?.state == .working)
    #expect(board.sessions["s"]?.project == "kivo")
    let n = board.apply(TranscriptProbe.Status(sessionID: "s", cwd: "/x/kivo", lastMessageAt: t0.addingTimeInterval(95), finished: true), now: t0.addingTimeInterval(100))
    #expect(n == .finished(project: "kivo", seconds: 95))
    #expect(board.sessions["s"]?.state == .idle)
  }

  @Test func unaTareaLargaNoCaducaMientrasHayaMensajes() {
    var board = ClaudeActivityBoard()
    let t0 = Date(timeIntervalSince1970: 1_793_032_800)
    board.apply(HookEvent(name: "UserPromptSubmit", sessionID: "s", cwd: "/x/taller", date: t0, message: nil))
    // 40 minutos después sigue escribiendo mensajes: no se debe dar por terminada.
    let later = t0.addingTimeInterval(40 * 60)
    board.apply(TranscriptProbe.Status(sessionID: "s", cwd: "/x/taller", lastMessageAt: later.addingTimeInterval(-20), finished: false), now: later)
    board.expire(now: later)
    #expect(board.sessions["s"]?.state == .working)
  }

  @Test func abrirUnaSesionViejaNoLaPoneATrabajar() {
    var board = ClaudeActivityBoard()
    let t0 = Date(timeIntervalSince1970: 1_793_032_800)
    board.apply(TranscriptProbe.Status(sessionID: "s", cwd: "/x/upb", lastMessageAt: t0, finished: false), now: t0.addingTimeInterval(3600))
    #expect(board.sessions["s"] == nil)
  }
}
