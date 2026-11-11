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

  @Test func elNombreDelChatEsElUltimoCustomTitle() {
    let tail = [#"{"type":"custom-title","customTitle":"Faro","sessionId":"a"}"#,
                line("assistant", "2026-10-26T16:40:00Z", stop: "end_turn"),
                #"{"type":"custom-title","customTitle":"Faro isla","sessionId":"a"}"#,
                #"{"type":"agent-name","agentName":"Otro","sessionId":"a"}"#].joined(separator: "\n")
    #expect(TranscriptProbe.title(tail: tail) == "Faro isla")
    #expect(TranscriptProbe.title(tail: line("user", "2026-10-26T16:40:00Z")) == nil)
    #expect(TranscriptProbe.title(tail: #"{"type":"custom-title","customTitle":"  "}"#) == nil)
  }

  @Test func elAvisoUsaElNombreDelChatYSiNoLaCarpeta() {
    var board = ClaudeActivityBoard()
    let t0 = Date(timeIntervalSince1970: 1_793_032_800)
    board.apply(HookEvent(name: "UserPromptSubmit", sessionID: "s", cwd: "/x/faro", date: t0, message: nil))
    board.setTitle("Faro", for: "s")
    #expect(board.apply(HookEvent(name: "Stop", sessionID: "s", cwd: "/x/faro", date: t0.addingTimeInterval(30), message: nil))
      == .finished(project: "Faro", seconds: 30))
    board.apply(HookEvent(name: "UserPromptSubmit", sessionID: "sin", cwd: "/x/tienda", date: t0, message: nil))
    #expect(board.apply(HookEvent(name: "Stop", sessionID: "sin", cwd: "/x/tienda", date: t0.addingTimeInterval(5), message: nil))
      == .finished(project: "tienda", seconds: 5))
  }

  @Test func elNombreLlegaAntesQueLaSesion() {
    // Faro reinició y el primer evento que ve de una sesión es el de "te necesita".
    var board = ClaudeActivityBoard()
    board.setTitle("Taller", for: "n")
    #expect(board.apply(HookEvent(name: "PermissionRequest", sessionID: "n", cwd: "/x/taller-web", date: Date(), message: nil))
      == .needsYou(project: "Taller"))
  }

  @Test func sinHooksElAvisoTambienUsaElNombreDelChat() {
    var board = ClaudeActivityBoard()
    let t0 = Date(timeIntervalSince1970: 1_793_032_800)
    board.apply(TranscriptProbe.Status(sessionID: "s", cwd: "/x/kivo", lastMessageAt: t0, finished: false, title: "Kivo"), now: t0)
    let n = board.apply(TranscriptProbe.Status(sessionID: "s", cwd: "/x/kivo", lastMessageAt: t0.addingTimeInterval(60), finished: true, title: "Kivo"),
      now: t0.addingTimeInterval(61))
    #expect(n == .finished(project: "Kivo", seconds: 60))
  }

  @Test func encuentraElRegistroPorElIdDeLaSesion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("faro-test-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("-Users-x-faro")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let f = dir.appendingPathComponent("abc.jsonl")
    try #"{"type":"custom-title","customTitle":"Faro"}"#.write(to: f, atomically: true, encoding: .utf8)
    #expect(TranscriptProbe.file(sessionID: "abc", root: root)?.lastPathComponent == "abc.jsonl")
    #expect(TranscriptProbe.title(of: f) == "Faro")
    #expect(TranscriptProbe.file(sessionID: "otra", root: root) == nil)
    #expect(TranscriptProbe.file(sessionID: "../abc", root: root) == nil)
  }
}
