import Foundation
import Testing
@testable import FaroCore

struct ActivityTests {
  let projects = [
    TrackedProject(name: "Producto", color: "#3B82F6", keywords: ["producto", "taller-app", "producto.software"]),
    TrackedProject(name: "Agencia", color: "#F59E0B", keywords: ["agencia", "web-agencia"]),
  ]
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func sample(_ s: TimeInterval, app: String = "Code", bundle: String? = "com.microsoft.VSCode", title: String? = nil,
    url: String? = nil, idle: TimeInterval = 0, media: Bool = false, folder: String? = nil, chat: String? = nil,
    meeting: Bool = false) -> ActivitySample {
    ActivitySample(date: t0.addingTimeInterval(s), bundleID: bundle, app: app, title: title, url: url.flatMap(URL.init(string:)),
      idle: idle, mediaPlaying: media, claudeFolder: folder, claudeTitle: chat, inMeeting: meeting)
  }

  @Test func elProyectoSaleDeLaCarpetaDeClaudeConUnaAppDeProgramar() {
    let c = ActivityClassifier(projects: projects, knownFolders: ["faro"])
    let r = c.classify(sample(0, app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Claude", folder: "taller-app", chat: "Arreglar pagos"))
    #expect(r == .init(kind: .work, project: "Producto", detail: "Arreglar pagos"))
    // Una carpeta conocida sin proyecto configurado queda con su propio nombre.
    #expect(c.classify(sample(0, app: "Claude", bundle: "com.anthropic.claudefordesktop", folder: "faro"))?.project == "faro")
  }

  @Test func laCarpetaDeClaudeNoCuentaSiAlFrenteHayOtraCosa() {
    let c = ActivityClassifier(projects: projects)
    let r = c.classify(sample(0, app: "Notas", bundle: "com.apple.Notes", title: "Lista del súper", folder: "taller-app"))
    #expect(r == .init(kind: .work, project: nil, detail: nil))
  }

  @Test func elDominioYElTituloTambienDelatanElProyecto() {
    let c = ActivityClassifier(projects: projects)
    #expect(c.classify(sample(0, app: "Dia", bundle: "company.thebrowser.dia", title: "Panel", url: "https://app.producto.software/pedidos"))?.project == "Producto")
    #expect(c.classify(sample(0, app: "Figma", bundle: "com.figma.Desktop", title: "Web agencia – Inicio"))?.project == "Agencia")
  }

  @Test func laPalabraTieneQueEstarCompleta() {
    let c = ActivityClassifier(projects: [TrackedProject(name: "Faro", color: "#000", keywords: ["faro"])])
    #expect(c.project(for: sample(0, title: "faroles de la calle")) == nil)
    #expect(c.project(for: sample(0, title: "faro — AppDelegate.swift")) == "Faro")
  }

  @Test func videosYStremioSonOcioYLoDemasTrabajo() {
    let c = ActivityClassifier(projects: projects)
    #expect(c.classify(sample(0, app: "Stremio", bundle: "com.stremio.stremio"))?.kind == .leisure)
    #expect(c.classify(sample(0, app: "Dia", bundle: "company.thebrowser.dia", url: "https://www.youtube.com/watch?v=1"))?.kind == .leisure)
    #expect(c.classify(sample(0, app: "Dia", bundle: "company.thebrowser.dia", url: "https://github.com/x/y"))?.kind == .work)
    // Un video sonando de fondo mientras se trabaja en otra app cuenta como trabajo.
    #expect(c.classify(sample(0, media: true))?.kind == .work)
  }

  @Test func unVideoDeEstudioOdeUnProyectoCuentaComoTrabajo() {
    let c = ActivityClassifier(projects: projects)
    let yt = { (t: String) in self.sample(0, app: "Dia", bundle: "company.thebrowser.dia", title: t, url: "https://www.youtube.com/watch?v=1") }
    #expect(c.classify(yt("Curso de SwiftUI desde cero - Clase 3 - YouTube"))?.kind == .work)
    #expect(c.classify(yt("How to deploy Next.js - YouTube"))?.kind == .work)
    #expect(c.classify(yt("Cómo armé el producto en un mes"))?.project == "Producto")
    #expect(c.classify(yt("Reaccionando a videos virales"))?.kind == .leisure)
    // Las apps de series siguen siendo ocio aunque el título diga "clase".
    #expect(c.classify(sample(0, app: "Stremio", bundle: nil, title: "La clase de 1984"))?.kind == .leisure)
  }

  @Test func sinTocarNadaNoCuentaSalvoUnVideoAlFrenteOUnaReunion() {
    let c = ActivityClassifier(projects: projects)
    #expect(c.classify(sample(0, idle: 600)) == nil)
    #expect(c.classify(sample(0, idle: 600, media: true)) == nil)
    #expect(c.classify(sample(0, app: "Stremio", bundle: nil, idle: 600, media: true))?.kind == .leisure)
    #expect(c.classify(sample(0, idle: 600, meeting: true)) == .init(kind: .work, project: "Reuniones", detail: nil))
  }

  @Test func losInstantesSeJuntanEnTramos() {
    let c = ActivityClassifier(projects: projects)
    let rec = ActivityRecorder(maxGap: 20)
    var spans: [ActivitySpan] = []
    for s in stride(from: 0.0, through: 60, by: 5) {
      let smp = sample(s, title: "taller-app — main.swift")
      rec.add(c.classify(smp), sample: smp, to: &spans)
    }
    for s in stride(from: 65.0, through: 100, by: 5) {
      let smp = sample(s, app: "Stremio", bundle: nil)
      rec.add(c.classify(smp), sample: smp, to: &spans)
    }
    // Un corte largo (Mac dormido) abre un tramo nuevo sin rellenar el hueco.
    let late = sample(1000, title: "taller-app — main.swift")
    rec.add(c.classify(late), sample: late, to: &spans)
    #expect(spans.count == 3)
    #expect(spans[0].duration == 60)
    #expect(spans[1].start == spans[0].end && spans[1].duration == 40)
    #expect(spans[2].duration == 0)
    let totals = ActivityTotals(spans)
    #expect(totals.work == 60 && totals.leisure == 40)
    #expect(totals.byProject.first?.name == "Producto")
  }

  @Test func deMensajesCorreoYBancosNoQuedaElTitulo() {
    let c = ActivityClassifier(projects: projects)
    let rec = ActivityRecorder()
    var spans: [ActivitySpan] = []
    let cases = [
      sample(0, app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "Mamá"),
      sample(30, app: "Microsoft Teams", bundle: "com.microsoft.teams2", title: "Chat | Ana Pérez"),
      sample(60, app: "Dia", bundle: "company.thebrowser.dia", title: "Ana Pérez - WhatsApp", url: "https://web.whatsapp.com/"),
      sample(90, app: "Dia", bundle: "company.thebrowser.dia", title: "Saldo - Bancolombia", url: "https://sucursalpersonas.transaccionesbancolombia.com/x"),
      sample(120, app: "Dia", bundle: "company.thebrowser.dia", title: "Mensajes", url: "https://www.instagram.com/direct/t/1"),
    ]
    for smp in cases { rec.add(c.classify(smp), sample: smp, to: &spans) }
    #expect(spans.count == cases.count)
    #expect(spans.allSatisfy { $0.title == nil })
    #expect(spans[2].host == "web.whatsapp.com")
    // Lo demás de Instagram sí guarda el título (no es privado).
    var other: [ActivitySpan] = []
    let feed = sample(0, app: "Dia", bundle: "company.thebrowser.dia", title: "Instagram", url: "https://www.instagram.com/alguien")
    rec.add(c.classify(feed), sample: feed, to: &other)
    #expect(other.first?.title == "Instagram")
  }

  @Test func deLasVentanasDeIncognitoNoQuedaNiElDominio() {
    let span = ActivityPrivacy.sanitize(ActivitySpan(start: t0, end: t0, bundleID: "com.google.Chrome", app: "Google Chrome",
      title: "Algo - Google Chrome (Incógnito)", host: "ejemplo.com", project: nil, kind: .work))
    #expect(span.title == "Ventana privada" && span.host == nil)
  }

  @Test func laVentanaPrivadaDeDiaSeReconocePorSuIdentificador() {
    #expect(ActivityPrivacy.isPrivateWindow(identifier: "bigIncognitoBrowserWindow_8C23BC42"))
    #expect(!ActivityPrivacy.isPrivateWindow(identifier: "bigBrowserWindow_8C23BC42"))
    var spans: [ActivitySpan] = []
    var smp = sample(0, app: "Dia", bundle: "company.thebrowser.dia", title: "Algo personal", url: "https://ejemplo.com/x")
    smp.privateWindow = true
    ActivityRecorder().add(ActivityClassifier(projects: projects).classify(smp), sample: smp, to: &spans)
    #expect(spans.first?.title == "Ventana privada" && spans.first?.host == nil)
  }

  @Test func loPrivadoTampocoSaleEnLoQueSeLeMandaAClaude() {
    let old = ActivitySpan(start: t0, end: t0.addingTimeInterval(600), bundleID: "net.whatsapp.WhatsApp", app: "WhatsApp",
      title: "Mamá", host: nil, project: nil, kind: .work)
    let text = TimeAnalyst.describe(day: "2026-11-24", spans: [old])
    #expect(!text.contains("Mamá"))
    #expect(text.contains("WhatsApp"))
  }

  @Test func losNombresQuedanSinMarcasInvisibles() {
    #expect(ActivityRecorder.clean("\u{200E}WhatsApp") == "WhatsApp")
    #expect(ActivityRecorder.clean("  ") == nil)
  }

  @Test func formatoDeDuraciones() {
    #expect(ActivityTotals.format(0) == "0 min")
    #expect(ActivityTotals.format(35 * 60) == "35 min")
    #expect(ActivityTotals.format(4 * 3600 + 12 * 60) == "4 h 12 min")
    #expect(ActivityTotals.format(2 * 3600) == "2 h")
    #expect(ActivityTotals.format(4 * 3600 + 5 * 60, short: true) == "4:05")
  }

  @Test func elDiaSeGuardaYSeLee() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("faro-tiempo-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ActivityStore(root: root)
    let span = ActivitySpan(start: t0, end: t0.addingTimeInterval(90), bundleID: "x", app: "Code", title: "a", host: nil,
      project: "Producto", kind: .work)
    store.save([span], day: "2026-11-24")
    #expect(store.spans(day: "2026-11-24") == [span])
    store.saveSummary(DaySummary(summary: "Bien", pending: [.init(project: "Producto", text: "Hacer commit")], verdict: "Buen día"), day: "2026-11-24")
    #expect(store.summary(day: "2026-11-24")?.pending.first?.text == "Hacer commit")
    #expect(store.days() == ["2026-11-24"])
  }

  @Test func elResumenSeLeeDeLaRespuestaDeClaude() throws {
    let json = #"{"resumen":"Trabajaste en pagos.","pendientes":[{"proyecto":"Producto","texto":"Commit de pagos"}],"balance":"Buen día."}"#
    let s = try JSONDecoder().decode(DaySummary.self, from: Data(json.utf8))
    #expect(s.pending.count == 1 && !s.pending[0].done && s.verdict == "Buen día.")
  }

  @Test func laDescripcionDelDiaLlevaProyectosChatsYPendientes() {
    let spans = [
      ActivitySpan(start: t0, end: t0.addingTimeInterval(3600), bundleID: "com.anthropic.claudefordesktop", app: "Claude",
        title: "Claude", host: nil, project: "Producto", detail: "Arreglar pagos", kind: .work),
      ActivitySpan(start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(4200), bundleID: nil, app: "Stremio",
        title: "Serie", host: nil, project: nil, kind: .leisure),
    ]
    let text = TimeAnalyst.describe(day: "2026-11-24", spans: spans,
      context: DayContext(carriedPending: [.init(project: "Agencia", text: "Responder propuesta")], repos: ["Producto: 3 cambios sin commit"]))
    #expect(text.contains("Producto: 1 h"))
    #expect(text.contains("Arreglar pagos"))
    #expect(text.contains("Ocio: 10 min"))
    #expect(text.contains("Responder propuesta"))
    #expect(text.contains("3 cambios sin commit"))
  }

  /// Con la API real: el resumen nombra lo trabajado y saca los pendientes de los cambios sin commit.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
  func conLaApiRealElResumenDelDiaTienePendientes() async throws {
    let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!
    let spans = [
      ActivitySpan(start: t0, end: t0.addingTimeInterval(7200), bundleID: "com.anthropic.claudefordesktop", app: "Claude",
        title: "Claude", host: nil, project: "Producto", detail: "Arreglar el cálculo de comisiones", kind: .work),
      ActivitySpan(start: t0.addingTimeInterval(7200), end: t0.addingTimeInterval(9000), bundleID: "company.thebrowser.dia",
        app: "Dia", title: "Propuesta comercial – Docs", host: "docs.google.com", project: "Agencia", kind: .work),
    ]
    let text = TimeAnalyst.describe(day: "2026-11-24", spans: spans,
      context: DayContext(repos: ["Producto (taller-app): 12 archivos con cambios sin commit en la rama comisiones"]))
    let s = try await TimeAnalyst(apiKey: key).summarizeDay(text)
    #expect(s.summary.localizedCaseInsensitiveContains("comisiones"))
    #expect(s.pending.contains { $0.project.contains("Producto") }, "\(s.pending)")
    #expect(!s.verdict.isEmpty)
  }
}
