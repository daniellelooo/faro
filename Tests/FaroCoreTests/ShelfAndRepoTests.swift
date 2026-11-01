import Foundation
import Testing
@testable import FaroCore

@Suite struct ClipboardHistoryTests {
  @Test func sinDuplicadosYConTope() {
    var h = ClipboardHistory(limit: 3)
    h.add("uno")
    h.add("dos")
    h.add("  uno  ")
    #expect(h.entries.map(\.text) == ["uno", "dos"])
    h.add("tres")
    h.add("cuatro")
    #expect(h.entries.map(\.text) == ["cuatro", "tres", "uno"])
    let added = h.add("   ")
    #expect(!added)
  }

  @Test func ignoraLoQueMarcanLosGestoresDeContrasenas() {
    #expect(!ClipboardHistory.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
    #expect(ClipboardHistory.shouldRecord(types: ["public.utf8-plain-text"]))
  }
}

@Suite struct ShelfStoreTests {
  @Test func guardaRutasSinRepetirYOlvidaLasBorradas() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bandeja-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.png")
    try Data().write(to: a)
    try Data().write(to: b)
    let file = dir.appendingPathComponent("bandeja.json")
    let s = ShelfStore(file: file)
    s.add([a, b])
    s.add([a])
    #expect(s.items.map(\.name) == ["a.pdf", "b.png"])
    try FileManager.default.removeItem(at: b)
    #expect(ShelfStore(file: file).items.map(\.name) == ["a.pdf"])
  }
}

@Suite struct RepoHealthTests {
  @Test func reconoceElRemotoDeGitHub() {
    #expect(RepoHealth.gitHubRepo(fromRemote: "https://github.com/acme/app.git") == "acme/app")
    #expect(RepoHealth.gitHubRepo(fromRemote: "git@github.com:daniellelooo/faro.git\n") == "daniellelooo/faro")
    #expect(RepoHealth.gitHubRepo(fromRemote: "https://gitlab.com/a/b.git") == nil)
  }

  @Test func separaDespliegueDeCI() {
    var h = RepoHealth(repo: "a/b")
    let status = #"{"state":"success","statuses":[{"context":"Vercel","state":"success","target_url":"https://vercel.com/x"}]}"#
    let runs = #"{"check_runs":[{"name":"Vercel Preview Comments","status":"completed","conclusion":"success"},{"name":"build","status":"completed","conclusion":"failure","html_url":"https://github.com/a/b/runs/1"}]}"#
    h.apply(statusJSON: Data(status.utf8), checkRunsJSON: Data(runs.utf8))
    #expect(h.deploy == .success)
    #expect(h.deployURL == "https://vercel.com/x")
    #expect(h.ci == .failure)
    #expect(h.ciURL == "https://github.com/a/b/runs/1")
  }

  @Test func sinChecksNoHayEstado() {
    var h = RepoHealth(repo: "a/b")
    h.apply(statusJSON: Data(#"{"state":"pending","statuses":[]}"#.utf8), checkRunsJSON: Data(#"{"check_runs":[]}"#.utf8))
    #expect(h.ci == nil)
    #expect(h.deploy == nil)
  }

  @Test func leeLosPRs() {
    var h = RepoHealth(repo: "a/b")
    let prs = #"[{"number":7,"title":"Nuevo","url":"u","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},{"__typename":"StatusContext","state":"SUCCESS"}]}]"#
    h.apply(pullRequestsJSON: Data(prs.utf8))
    #expect(h.pullRequests.count == 1)
    #expect(h.pullRequests[0].checks == .pending)
  }
}
