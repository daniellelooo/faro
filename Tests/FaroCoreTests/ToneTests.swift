import Testing
@testable import FaroCore

@Suite struct ToneTests {
  @Test func appsDeCodigoSonLiterales() {
    #expect(ToneResolver.resolve(bundleID: "com.anthropic.claudefordesktop", url: nil) == .literal)
    #expect(ToneResolver.resolve(bundleID: "dev.warp.Warp-Stable", url: nil) == .literal)
    #expect(ToneResolver.resolve(bundleID: "com.microsoft.VSCode", url: nil) == .literal)
  }
  @Test func whatsappEsCasual() {
    #expect(ToneResolver.resolve(bundleID: "net.whatsapp.WhatsApp", url: nil) == .casual)
  }
  @Test func navegadorSegunLaPestana() {
    let arc = "company.thebrowser.Browser"
    #expect(ToneResolver.resolve(bundleID: arc, url: "https://mail.google.com/mail/u/0/#inbox") == .formal)
    #expect(ToneResolver.resolve(bundleID: arc, url: "https://app.slack.com/client/T1/C2") == .casual)
    #expect(ToneResolver.resolve(bundleID: "com.google.Chrome", url: "https://web.whatsapp.com/") == .casual)
    #expect(ToneResolver.resolve(bundleID: arc, url: "https://claude.ai/new") == .literal)
    #expect(ToneResolver.resolve(bundleID: arc, url: "https://elespectador.com") == .neutral)
    #expect(ToneResolver.resolve(bundleID: arc, url: nil) == .neutral)
  }
  @Test func desconocidoEsNeutro() {
    #expect(ToneResolver.resolve(bundleID: "com.ejemplo.raro", url: nil) == .neutral)
    #expect(ToneResolver.resolve(bundleID: nil, url: nil) == .neutral)
  }
  @Test func elPromptIncluyeElDiccionarioYLaReglaDeNoResponder() {
    let dict = PersonalDictionary(words: ["Supabase", "Kivo"])
    let s = CleanupPrompt.system(tone: .casual, dictionary: dict)
    #expect(s.contains("Supabase"))
    #expect(s.contains("Kivo"))
    #expect(s.lowercased().contains("nunca respondas"))
    #expect(CleanupPrompt.user(raw: "hola") == "<transcripcion>\nhola\n</transcripcion>")
  }
}
