import Foundation
import Testing
@testable import FaroCore

@Suite struct KeychainTests {
  @Test func escribeYLeeSinVentanaDeContrasena() {
    let service = "dicta-prueba-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service) }
    #expect(KeychainStore.read(service: service) == nil)
    #expect(KeychainStore.write(service: service, value: "sk-ant-prueba-123"))
    #expect(KeychainStore.read(service: service) == "sk-ant-prueba-123")
    #expect(KeychainStore.write(service: service, value: "sk-ant-otra"))
    #expect(KeychainStore.read(service: service) == "sk-ant-otra")
  }

  @Test func escapaComillasYBarrasYRechazaSaltosDeLinea() {
    #expect(KeychainStore.quoted(#"a"b\c"#) == #""a\"b\\c""#)
    #expect(KeychainStore.quoted("a\nadd-generic-password") == nil)
    let service = "dicta-prueba-\(UUID().uuidString)"
    defer { KeychainStore.delete(service: service) }
    let raro = #"sk-"con comillas" y \barras\"#
    #expect(KeychainStore.write(service: service, value: raro))
    #expect(KeychainStore.read(service: service) == raro)
    #expect(!KeychainStore.write(service: service, value: "a\nb"))
  }

  /// Solo si ya hay una clave guardada en el Llavero (servicio dicta-anthropic): se lee sin pedir contraseña.
  @Test(.enabled(if: KeychainStore.read(service: KeychainStore.apiKeyService) != nil))
  func laClaveGuardadaSeLee() {
    #expect(KeychainStore.read(service: KeychainStore.apiKeyService)?.hasPrefix("sk-ant-") == true)
  }
}

@Suite struct MigrationTests {
  @Test func combinaCarpetasSinPisarNada() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("migracion-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("Dicta/reuniones/r1"), withIntermediateDirectories: true)
    try "viejo".write(to: root.appendingPathComponent("Dicta/historial.json"), atomically: true, encoding: .utf8)
    try "r1".write(to: root.appendingPathComponent("Dicta/reuniones/r1/reunion.json"), atomically: true, encoding: .utf8)
    // Faro ya creó su carpeta de reuniones vacía antes de migrar.
    try fm.createDirectory(at: root.appendingPathComponent("Faro/reuniones"), withIntermediateDirectories: true)
    Migration.moveLegacyData(support: root)
    #expect(fm.fileExists(atPath: root.appendingPathComponent("Faro/historial.json").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("Faro/reuniones/r1/reunion.json").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("Dicta").path))
  }
}
