import FaroCore
import Foundation
import Observation

/// Un proyecto en el que trabajas con Claude Code, con su estado de git.
struct ProjectInfo: Identifiable, Equatable {
  var id: String { root }
  var root: String
  var name: String
  var costToday = 0.0
  var costWeek = 0.0
  /// Costo de los últimos 7 días, del más viejo a hoy.
  var week: [Double] = Array(repeating: 0, count: 7)
  var sessions = 0
  var lastActivity: Date?
  var git: GitStatus?
  var health: RepoHealth?
}

struct GitStatus: Equatable, Sendable {
  var branch: String
  var changes: Int
  var lastCommit: String?
  var lastCommitDate: Date?
}

/// Proyectos recientes a partir del uso de Claude Code, agrupados por repositorio.
@MainActor @Observable
final class ProjectsService {
  var projects: [ProjectInfo] = []
  @ObservationIgnored private var gitCache: [String: (GitStatus?, Date)] = [:]
  @ObservationIgnored private var healthCache: [String: (RepoHealth?, Date)] = [:]

  func update(from report: UsageReport) {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let days = (0..<7).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
    let cutoff = Date().addingTimeInterval(-14 * 86400)
    var byRoot: [String: ProjectInfo] = [:]
    for p in report.projects {
      guard let last = p.lastActivity, last > cutoff else { continue }
      let root = Self.repositoryRoot(for: p.path)
      var info = byRoot[root] ?? ProjectInfo(root: root, name: URL(fileURLWithPath: root).lastPathComponent)
      info.sessions += p.sessions
      if last > (info.lastActivity ?? .distantPast) { info.lastActivity = last }
      for (i, d) in days.enumerated() { info.week[i] += p.costByDay[d] ?? 0 }
      byRoot[root] = info
    }
    var list = byRoot.values.map { p -> ProjectInfo in
      var p = p
      p.costToday = p.week.last ?? 0
      p.costWeek = p.week.reduce(0, +)
      p.git = gitCache[p.root]?.0 ?? projects.first { $0.root == p.root }?.git
      p.health = healthCache[p.root]?.0 ?? projects.first { $0.root == p.root }?.health
      return p
    }
    list.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    projects = Array(list.prefix(8))
    refreshGit()
    refreshHealth()
  }

  /// CI, despliegue y PRs desde GitHub con `gh`; cada repo como mucho cada 5 minutos.
  private func refreshHealth() {
    guard let gh = Self.ghPath else { return }
    let roots = projects.map(\.root).filter { Date().timeIntervalSince(healthCache[$0]?.1 ?? .distantPast) > 300 }
    guard !roots.isEmpty else { return }
    for r in roots { healthCache[r] = (healthCache[r]?.0, Date()) }
    Task.detached(priority: .utility) {
      var results: [String: RepoHealth?] = [:]
      for r in roots { results[r] = Self.repoHealth(at: r, gh: gh) }
      let found = results
      await MainActor.run {
        for (r, h) in found {
          self.healthCache[r] = (h, Date())
          if let i = self.projects.firstIndex(where: { $0.root == r }) { self.projects[i].health = h }
        }
      }
    }
  }

  nonisolated static let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

  nonisolated static func repoHealth(at root: String, gh: String) -> RepoHealth? {
    guard let remote = git(root, ["remote", "get-url", "origin"]), let repo = RepoHealth.gitHubRepo(fromRemote: remote) else { return nil }
    // El commit que GitHub conoce de esta rama (el de upstream); si no hay upstream, el local.
    guard let sha = git(root, ["rev-parse", "@{u}"]) ?? git(root, ["rev-parse", "HEAD"]) else { return nil }
    var h = RepoHealth(repo: repo)
    h.apply(statusJSON: run(gh, ["api", "repos/\(repo)/commits/\(sha)/status"]),
            checkRunsJSON: run(gh, ["api", "repos/\(repo)/commits/\(sha)/check-runs"]))
    h.apply(pullRequestsJSON: run(gh, ["pr", "list", "--repo", repo, "--state", "open", "--limit", "10",
                                       "--json", "number,title,url,isDraft,statusCheckRollup"]))
    return h
  }

  nonisolated static func run(_ exe: String, _ args: [String]) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["GH_PROMPT_DISABLED"] = "1"
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
  }

  /// git corre fuera del hilo principal; cada repo se vuelve a mirar como mucho cada 2 minutos.
  private func refreshGit() {
    let roots = projects.map(\.root).filter { Date().timeIntervalSince(gitCache[$0]?.1 ?? .distantPast) > 120 }
    guard !roots.isEmpty else { return }
    for r in roots { gitCache[r] = (gitCache[r]?.0, Date()) }
    Task.detached(priority: .utility) {
      var results: [String: GitStatus?] = [:]
      for r in roots { results[r] = Self.gitStatus(at: r) }
      let found = results
      await MainActor.run {
        for (r, g) in found {
          self.gitCache[r] = (g, Date())
          if let i = self.projects.firstIndex(where: { $0.root == r }) { self.projects[i].git = g }
        }
      }
    }
  }

  /// Sube desde la carpeta de la sesión hasta encontrar el repositorio (sin pasar del home).
  nonisolated static func repositoryRoot(for path: String) -> String {
    let home = NSHomeDirectory()
    // Worktrees de Claude Code (aunque ya se hayan borrado) cuentan como su repo.
    if let r = path.range(of: "/.claude/worktrees/") { return String(path[..<r.lowerBound]) }
    var url = URL(fileURLWithPath: path)
    while url.path.hasPrefix(home), url.path != home {
      let git = url.appendingPathComponent(".git")
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
        // Un worktree tiene un archivo .git que apunta al repo principal: se agrupa con él.
        if !isDir.boolValue, let text = try? String(contentsOf: git, encoding: .utf8),
          let r = text.range(of: "gitdir: "), let cut = text[r.upperBound...].range(of: "/.git/") {
          return String(text[r.upperBound..<cut.lowerBound])
        }
        return url.path
      }
      url.deleteLastPathComponent()
    }
    return path
  }

  nonisolated static func gitStatus(at root: String) -> GitStatus? {
    guard FileManager.default.fileExists(atPath: root + "/.git") else { return nil }
    guard let branch = git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) else { return nil }
    let changes = git(root, ["status", "--porcelain"])?.split(separator: "\n").count ?? 0
    var subject: String?
    var date: Date?
    if let log = git(root, ["log", "-1", "--format=%s%x1f%ct"]) {
      let parts = log.split(separator: "\u{1f}", maxSplits: 1)
      subject = parts.first.map(String.init)
      if parts.count > 1, let t = Double(parts[1]) { date = Date(timeIntervalSince1970: t) }
    }
    return GitStatus(branch: branch, changes: changes, lastCommit: subject, lastCommitDate: date)
  }

  nonisolated static func git(_ root: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin"]
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
