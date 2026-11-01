import Foundation
import Testing
@testable import FaroCore

@Suite struct StatsAndStyleTests {
  func entry(_ text: String, daysAgo: Double, seconds: Double = 1.5) -> HistoryEntry {
    HistoryEntry(date: Date().addingTimeInterval(-daysAgo * 86400), raw: text, final: text, app: "Notas", usedFallback: false, seconds: seconds)
  }

  @Test func estadisticasCuentanPalabrasDeLaSemanaYTiempoAhorrado() {
    let entries = [entry("uno dos tres cuatro", daysAgo: 1), entry("cinco seis", daysAgo: 2, seconds: 2.5), entry("viejo texto de antes", daysAgo: 10)]
    let s = HistoryStats(entries: entries)
    #expect(s.wordsThisWeek == 6)
    #expect(s.totalWords == 10)
    #expect(s.dictationsThisWeek == 2)
    #expect(abs(s.averageSeconds - 2.0) < 0.01)
    // 40 palabras por minuto escribiendo contra 150 hablando.
    #expect(abs(s.minutesSavedThisWeek - (6.0 / 40 - 6.0 / 150)) < 0.001)
  }

  @Test func historialViejoSinCamposNuevosSeLeeBien() throws {
    let json = #"[{"id":"7F1F0D4E-2F5C-4E1A-9E61-0D1D2B9B3C11","date":"2026-10-22T14:12:23Z","raw":"hola","final":"Hola.","app":"Claude","usedFallback":false,"seconds":1.2}]"#
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let e = try d.decode([HistoryEntry].self, from: Data(json.utf8))
    #expect(e.first?.final == "Hola.")
    #expect(e.first?.bundleID == nil)
  }

  @Test func categoriasDeApps() {
    #expect(AppCategory.of(bundleID: "net.whatsapp.WhatsApp", url: nil) == .messaging)
    #expect(AppCategory.of(bundleID: "company.thebrowser.Browser", url: "https://mail.google.com/x") == .email)
    #expect(AppCategory.of(bundleID: "com.anthropic.claudefordesktop", url: nil) == .code)
    #expect(AppCategory.of(bundleID: "notion.id", url: nil) == .documents)
    #expect(AppCategory.of(bundleID: "com.raro", url: nil) == .other)
  }

  @Test func elEstiloElegidoPorCategoriaManda() {
    let styles = StylePreferences(tones: [.messaging: .formal])
    #expect(styles.tone(bundleID: "net.whatsapp.WhatsApp", url: nil) == .formal)
    #expect(styles.tone(bundleID: "com.apple.mail", url: nil) == .formal)
    #expect(StylePreferences().tone(bundleID: "net.whatsapp.WhatsApp", url: nil) == .casual)
  }
}
