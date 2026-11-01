import Foundation

/// Clave de la API en el Llavero de macOS, leída y escrita siempre con `/usr/bin/security`.
///
/// Por qué no SecItem directo: el ítem lo creó `security` y macOS solo lo deja leer sin preguntar a la app que lo
/// creó. A una app firmada sin equipo de Apple la reconoce por la huella de su ejecutable, que cambia en cada
/// compilación, así que pedía la contraseña del Mac en cada arranque. Pasando por `security` nunca pregunta.
public enum KeychainStore {
  public static let apiKeyService = "dicta-anthropic"
  static let tool = "/usr/bin/security"

  public static func read(service: String) -> String? {
    let out = Pipe()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// La clave se pasa por la entrada estándar de `security -i`, no como argumento: así no aparece en la lista de procesos.
  /// Cada valor va entre comillas dobles con `\` y `"` escapados; los caracteres de control (que cortarían la línea
  /// del comando) se rechazan.
  @discardableResult
  public static func write(service: String, value: String) -> Bool {
    guard !value.isEmpty, let v = quoted(value), let s = quoted(service), let a = quoted(NSUserName()) else { return false }
    let input = Pipe()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-i"]
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    let command = "add-generic-password -U -a \(a) -s \(s) -w \(v)\n"
    input.fileHandleForWriting.write(Data(command.utf8))
    input.fileHandleForWriting.closeFile()
    p.waitUntilExit()
    return read(service: service) == value
  }

  /// Argumento para la línea de comandos de `security -i`: entre comillas dobles, con `\` y `"` escapados.
  /// nil si trae caracteres de control (un salto de línea terminaría el comando y empezaría otro).
  static func quoted(_ s: String) -> String? {
    guard !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  public static func delete(service: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["delete-generic-password", "-s", service]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
  }
}
