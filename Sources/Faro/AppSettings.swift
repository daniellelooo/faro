import FaroCore
import Foundation
import Observation

/// Preferencias de Faro, guardadas en UserDefaults. La clave de la API va aparte, en el Llavero.
@MainActor @Observable
final class AppSettings {
  private let defaults = UserDefaults.standard

  var localOnly: Bool { didSet { defaults.set(localOnly, forKey: "soloLocal") } }
  var showIdlePill: Bool { didSet { defaults.set(showIdlePill, forKey: "pildora") } }
  var indicatorStyle: IndicatorStyle { didSet { defaults.set(indicatorStyle.rawValue, forKey: "indicador") } }
  var hidePillWhenWatching: Bool { didSet { defaults.set(hidePillWhenWatching, forKey: "pildoraOcultaEnVideo") } }
  /// Ocultar también en cualquier app en pantalla completa (no solo en las de video).
  /// Con un monitor externo, la isla va a la pantalla donde está el puntero.
  /// Las teclas de volumen y brillo se muestran en la isla (en vez del indicador de macOS).
  var volumeBrightnessInIsland: Bool { didSet { defaults.set(volumeBrightnessInIsland, forKey: "volumenBrilloEnIsla") } }
  var islandFollowsPointer: Bool { didSet { defaults.set(islandFollowsPointer, forKey: "islaSigueAlPuntero") } }
  /// Invertir el scroll de la rueda del mouse y, aparte, el del trackpad.
  var invertMouseScroll: Bool { didSet { defaults.set(invertMouseScroll, forKey: "invertirScrollMouse") } }
  var invertTrackpadScroll: Bool { didSet { defaults.set(invertTrackpadScroll, forKey: "invertirScrollTrackpad") } }
  var steppedScrollInGames: Bool { didSet { defaults.set(steppedScrollInGames, forKey: "scrollPorPasosEnJuegos") } }
  var hideInFullscreen: Bool { didSet { defaults.set(hideInFullscreen, forKey: "ocultarEnPantallaCompleta") } }
  /// Micrófono para dictar y grabar reuniones (ver `MicInfo.choice`).
  var microphone: String { didSet { defaults.set(microphone, forKey: MicInfo.choiceKey) } }
  var words: [String] { didSet { defaults.set(words, forKey: "diccionarioPalabras") } }
  var styles: StylePreferences {
    didSet { defaults.set(try? JSONEncoder().encode(styles), forKey: "estilos") }
  }
  var idleLeft: IdleItem { didSet { defaults.set(idleLeft.rawValue, forKey: "islaReposoIzquierda") } }
  var idleRight: IdleItem { didSet { defaults.set(idleRight.rawValue, forKey: "islaReposoDerecha") } }
  /// Carpeta con las notas de contexto (.md) del copiloto de reuniones. Vacía = copiloto desactivado.
  var copilotNotesFolder: String { didSet { defaults.set(copilotNotesFolder, forKey: "carpetaNotasCopiloto") } }
  var paused = false

  init() {
    localOnly = defaults.bool(forKey: "soloLocal")
    showIdlePill = defaults.object(forKey: "pildora") as? Bool ?? true
    indicatorStyle = IndicatorStyle(rawValue: defaults.string(forKey: "indicador") ?? "") ?? .island
    idleLeft = IdleItem(rawValue: defaults.string(forKey: "islaReposoIzquierda") ?? "") ?? .limit5h
    idleRight = IdleItem(rawValue: defaults.string(forKey: "islaReposoDerecha") ?? "") ?? .costToday
    hidePillWhenWatching = defaults.object(forKey: "pildoraOcultaEnVideo") as? Bool ?? true
    volumeBrightnessInIsland = defaults.object(forKey: "volumenBrilloEnIsla") as? Bool ?? true
    islandFollowsPointer = defaults.object(forKey: "islaSigueAlPuntero") as? Bool ?? true
    invertMouseScroll = defaults.bool(forKey: "invertirScrollMouse")
    invertTrackpadScroll = defaults.bool(forKey: "invertirScrollTrackpad")
    steppedScrollInGames = defaults.object(forKey: "scrollPorPasosEnJuegos") as? Bool ?? true
    hideInFullscreen = defaults.object(forKey: "ocultarEnPantallaCompleta") as? Bool ?? false
    microphone = MicInfo.choice
    copilotNotesFolder = defaults.string(forKey: "carpetaNotasCopiloto") ?? MeetingCopilot.defaultFolder.path
    if let saved = defaults.stringArray(forKey: "diccionarioPalabras") {
      words = saved
    } else if let legacy = defaults.string(forKey: "diccionario") {
      words = legacy.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    } else {
      words = PersonalDictionary.default.words
    }
    if let data = defaults.data(forKey: "estilos"), let s = try? JSONDecoder().decode(StylePreferences.self, from: data) {
      styles = s
    } else {
      styles = StylePreferences()
    }
  }

  var scrollInversion: ScrollInversion { ScrollInversion(mouse: invertMouseScroll, trackpad: invertTrackpadScroll) }

  var dictionary: PersonalDictionary { PersonalDictionary(words: words) }
}
