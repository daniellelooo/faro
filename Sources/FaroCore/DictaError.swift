import Foundation

public enum DictaError: LocalizedError, Equatable {
  case whisperNotInstalled
  case modelMissing(String)
  case serverDidNotStart
  case transcriptionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .whisperNotInstalled:
      return "No encuentro whisper.cpp. Instálalo con: brew install whisper-cpp"
    case .modelMissing(let path):
      return "Falta el modelo de voz en \(path). Vuelve a descargarlo desde Ajustes."
    case .serverDidNotStart:
      return "El motor de transcripción no arrancó. Cierra Faro y ábrela de nuevo."
    case .transcriptionFailed(let detail):
      return "No se pudo transcribir el audio (\(detail))."
    }
  }
}
