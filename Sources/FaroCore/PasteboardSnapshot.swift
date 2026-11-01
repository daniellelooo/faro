import AppKit

/// Copia exacta de lo que había en el portapapeles (todos los ítems y todos sus tipos) para restaurarlo después de pegar.
public struct PasteboardSnapshot {
  let items: [[(NSPasteboard.PasteboardType, Data)]]

  public static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot {
    let items = (pb.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    return PasteboardSnapshot(items: items)
  }

  public func restore(to pb: NSPasteboard = .general) {
    pb.clearContents()
    guard !items.isEmpty else { return }
    let restored = items.map { pairs -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in pairs { item.setData(data, forType: type) }
      return item
    }
    pb.writeObjects(restored)
  }
}
