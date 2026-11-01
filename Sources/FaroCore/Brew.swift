import Foundation

public struct BrewPackage: Equatable, Sendable, Identifiable {
  public var id: String { (isCask ? "cask:" : "") + name }
  public var name: String
  public var installed: String
  public var latest: String
  public var isCask: Bool
  public init(name: String, installed: String, latest: String, isCask: Bool) {
    self.name = name
    self.installed = installed
    self.latest = latest
    self.isCask = isCask
  }
}

/// Lee la salida de `brew outdated --json=v2`.
public enum BrewOutdated {
  public static let brew = "/opt/homebrew/bin/brew"

  public static func parse(_ data: Data) throws -> [BrewPackage] {
    guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    func items(_ key: String, cask: Bool) -> [BrewPackage] {
      (o[key] as? [[String: Any]] ?? []).compactMap { p in
        guard let name = p["name"] as? String else { return nil }
        let installed = (p["installed_versions"] as? [String])?.last ?? (p["installed_versions"] as? String) ?? "?"
        return BrewPackage(name: name, installed: installed, latest: p["current_version"] as? String ?? "?", isCask: cask)
      }
    }
    return items("formulae", cask: false) + items("casks", cask: true)
  }
}
