import Foundation

/// La app se llamaba Dicta: sus datos (historial, reuniones, modelo de voz, datos de Claude) se mueven a la carpeta de
/// Faro. Corre al arrancar, antes de crear cualquier almacén.
public enum Migration {
  public static func moveLegacyData(support: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")) {
    let old = support.appendingPathComponent("Dicta")
    let new = support.appendingPathComponent("Faro")
    guard FileManager.default.fileExists(atPath: old.path) else { return }
    merge(old, into: new)
  }

  /// Mueve todo de `from` a `to` sin pisar lo que ya exista; combina carpetas que existan en ambos lados.
  static func merge(_ from: URL, into to: URL) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: to.path) {
      try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.moveItem(at: from, to: to)
      return
    }
    for item in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
      let source = from.appendingPathComponent(item)
      let target = to.appendingPathComponent(item)
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
        if isDir.boolValue { merge(source, into: target) }
      } else {
        try? fm.moveItem(at: source, to: target)
      }
    }
    if ((try? fm.contentsOfDirectory(atPath: from.path)) ?? []).isEmpty { try? fm.removeItem(at: from) }
  }
}
