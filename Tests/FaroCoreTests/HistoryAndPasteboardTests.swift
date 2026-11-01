import AppKit
import Foundation
import Testing
@testable import FaroCore

@Suite struct HistoryAndPasteboardTests {
  @Test func historialGuardaRecargaYRecortaA100() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = HistoryStore(file: file)
    for i in 0..<105 {
      store.add(HistoryEntry(date: Date(), raw: "crudo \(i)", final: "limpio \(i)", app: "Notas", usedFallback: false, seconds: 1))
    }
    #expect(store.entries.count == 100)
    #expect(store.entries.first?.final == "limpio 104")
    let reloaded = HistoryStore(file: file)
    #expect(reloaded.entries.count == 100)
    #expect(reloaded.entries.last?.final == "limpio 5")
  }

  @Test func elPortapapelesSeRestauraConTodosSusTipos() throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("dicta-prueba-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setString("lo que tenía copiado", forType: .string)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    item.setData(png, forType: .png)
    pb.writeObjects([item])

    let snap = PasteboardSnapshot.capture(pb)
    pb.clearContents()
    pb.setString("texto dictado", forType: .string)
    #expect(pb.string(forType: .string) == "texto dictado")
    snap.restore(to: pb)
    #expect(pb.string(forType: .string) == "lo que tenía copiado")
    #expect(pb.data(forType: .png) == png)
  }
}
