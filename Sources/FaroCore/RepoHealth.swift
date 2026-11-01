import Foundation

/// Estado en GitHub del último commit de la rama actual: CI, despliegue (Vercel) y PRs abiertos.
public struct RepoHealth: Sendable, Equatable {
  public enum State: String, Sendable { case success, pending, failure }

  public struct PullRequest: Sendable, Equatable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var title: String
    public var url: String
    public var draft: Bool
    public var checks: State?
  }

  public var repo: String
  public var ci: State?
  public var ciURL: String?
  public var deploy: State?
  public var deployURL: String?
  public var pullRequests: [PullRequest] = []

  public init(repo: String) { self.repo = repo }

  /// `owner/repo` a partir de la URL del remoto (https o ssh), solo si es GitHub.
  public static func gitHubRepo(fromRemote remote: String) -> String? {
    var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasSuffix(".git") { s.removeLast(4) }
    for prefix in ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/"] where s.hasPrefix(prefix) {
      let rest = String(s.dropFirst(prefix.count))
      let parts = rest.split(separator: "/")
      return parts.count == 2 ? rest : nil
    }
    return nil
  }

  static func isDeploy(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.hasPrefix("vercel") || n.contains("netlify") || n.contains("deploy")
  }

  /// Combina `GET /commits/{ref}/status` y `GET /commits/{ref}/check-runs`.
  public mutating func apply(statusJSON: Data?, checkRunsJSON: Data?) {
    var ciStates: [String] = []
    var deployStates: [String] = []
    if let d = statusJSON, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
      let statuses = o["statuses"] as? [[String: Any]] {
      for s in statuses {
        let context = s["context"] as? String ?? ""
        let state = s["state"] as? String ?? ""
        if Self.isDeploy(context) {
          deployStates.append(state)
          if deployURL == nil { deployURL = s["target_url"] as? String }
        } else {
          ciStates.append(state)
          if ciURL == nil { ciURL = s["target_url"] as? String }
        }
      }
    }
    if let d = checkRunsJSON, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
      let runs = o["check_runs"] as? [[String: Any]] {
      for r in runs {
        let name = r["name"] as? String ?? ""
        // Los comentarios de vista previa de Vercel no son CI ni el despliegue en sí.
        if Self.isDeploy(name) { continue }
        let status = r["status"] as? String ?? ""
        ciStates.append(status == "completed" ? (r["conclusion"] as? String ?? "success") : "pending")
        if ciURL == nil { ciURL = r["html_url"] as? String }
      }
    }
    ci = Self.combine(ciStates)
    deploy = Self.combine(deployStates)
  }

  /// Rojo si algo falló; amarillo si algo sigue corriendo; verde si todo terminó bien.
  public static func combine(_ states: [String]) -> State? {
    guard !states.isEmpty else { return nil }
    let failures: Set<String> = ["failure", "error", "cancelled", "timed_out", "action_required", "startup_failure"]
    if states.contains(where: failures.contains) { return .failure }
    let done: Set<String> = ["success", "neutral", "skipped", "completed"]
    if states.contains(where: { !done.contains($0) }) { return .pending }
    return .success
  }

  /// Salida de `gh pr list --json number,title,url,isDraft,statusCheckRollup`.
  public mutating func apply(pullRequestsJSON d: Data?) {
    guard let d, let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
    pullRequests = list.compactMap { p in
      guard let n = p["number"] as? Int else { return nil }
      var states: [String] = []
      for c in p["statusCheckRollup"] as? [[String: Any]] ?? [] {
        if let conclusion = c["conclusion"] as? String, !conclusion.isEmpty {
          states.append(conclusion.lowercased())
        } else if let st = c["state"] as? String {
          states.append(st.lowercased())
        } else if let st = c["status"] as? String {
          states.append(st.lowercased() == "completed" ? "success" : "pending")
        }
      }
      return PullRequest(number: n, title: p["title"] as? String ?? "", url: p["url"] as? String ?? "",
        draft: p["isDraft"] as? Bool ?? false, checks: Self.combine(states))
    }
  }
}
