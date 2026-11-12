import Testing
@testable import FaroCore

@Suite struct NegationGuardTests {
  @Test func detectaUnaNegacionBorrada() {
    #expect(NegationGuard.lostNegation(
      raw: "Se pierde la isla dinámica. Así no es en un video de pantalla completo.",
      cleaned: "Se pierde la isla dinámica en un video de pantalla completa."))
  }

  @Test func conservarLaNegacionEstaBien() {
    #expect(!NegationGuard.lostNegation(
      raw: "Se pierde la isla. Así no es en un video de pantalla completo.",
      cleaned: "Se pierde la isla, así no esté en un video de pantalla completa."))
  }

  @Test func lasAutocorreccionesSiQuitanElNo() {
    #expect(!NegationGuard.lostNegation(raw: "Nos vemos el martes, no, perdón, el miércoles.", cleaned: "Nos vemos el miércoles."))
    #expect(!NegationGuard.lostNegation(raw: "Somos tres personas, no, cuatro con Laura.", cleaned: "Somos cuatro personas con Laura."))
  }

  @Test func lasRepeticionesCuentanUnaVez() {
    #expect(!NegationGuard.lostNegation(raw: "Eh, no no sé si llegue.", cleaned: "No sé si llegue."))
  }
}
