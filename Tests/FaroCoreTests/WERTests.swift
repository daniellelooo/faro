import Testing
@testable import FaroCore

@Suite struct WERTests {
  @Test func identicosDanCero() {
    #expect(WER.compute(reference: "hola mundo", hypothesis: "hola mundo") == 0)
  }
  @Test func unaSustitucionEnCuatroPalabras() {
    #expect(WER.compute(reference: "la reunión es mañana", hypothesis: "la reunión fue mañana") == 0.25)
  }
  @Test func puntuacionYMayusculasNoCuentan() {
    #expect(WER.compute(reference: "Hola, mundo.", hypothesis: "hola mundo") == 0)
    #expect(WER.compute(reference: "- uno\n- dos", hypothesis: "uno, dos") == 0)
  }
  @Test func normalizaTildesNo() {
    // Las tildes sí cuentan: "miercoles" sin tilde es un error de escritura.
    #expect(WER.compute(reference: "miércoles", hypothesis: "miercoles") == 1)
  }
}
