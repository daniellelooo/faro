import FaroCore
import IOKit.ps
import SwiftUI

/// Lo que la isla puede mostrar a cada lado del notch cuando no pasa nada.
enum IdleItem: String, CaseIterable, Identifiable, Codable {
  case attention, projects, shelf, limit5h, limitWeek, costToday, clock, date, battery, faro, nothing
  var id: String { rawValue }

  var title: String {
    switch self {
    case .attention: return "Pendientes (CI, despliegues, Claude)"
    case .projects: return "Estado de tus proyectos"
    case .shelf: return "Archivos en la bandeja"
    case .limit5h: return "Límite de 5 horas"
    case .limitWeek: return "Límite semanal"
    case .costToday: return "Gasto de hoy (precio API)"
    case .clock: return "Hora"
    case .date: return "Fecha"
    case .battery: return "Batería"
    case .faro: return "Ícono de Faro"
    case .nothing: return "Nada"
    }
  }

  /// Ancho aproximado del contenido, para que la isla se abra lo justo.
  var width: CGFloat {
    switch self {
    case .attention: return 40
    case .projects: return 44
    case .shelf: return 34
    case .limit5h: return 48
    case .limitWeek: return 68
    case .costToday: return 38
    case .clock: return 36
    case .date: return 44
    case .battery: return 46
    case .faro: return 27
    case .nothing: return 0
    }
  }
}

/// Estado de la batería interna (nil en Macs de escritorio).
enum Battery {
  static func read() -> (percent: Int, charging: Bool)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for ps in list {
      guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
        d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
      else { continue }
      let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
      return (cur * 100 / max, charging)
    }
    return nil
  }
}

struct IdleItemView: View {
  let item: IdleItem
  let state: OverlayState

  var body: some View {
    switch item {
    case .attention:
      let items = state.app?.attentionItems() ?? []
      if let first = items.first {
        HStack(spacing: 4) {
          Image(systemName: first.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(first.color)
          if items.count > 1 { text("\(items.count)", color: first.color) }
        }
        .help(items.map(\.text).joined(separator: "\n"))
      } else {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green.opacity(0.75))
          .help("Todo en orden")
      }
    case .projects:
      let health = (state.claude?.projects.projects ?? []).compactMap(\.health)
      let checks = health.flatMap { [$0.ci, $0.deploy] }.compactMap { $0 }
      HStack(spacing: 3) {
        ForEach(Array(checks.prefix(6).enumerated()), id: \.offset) { _, st in
          Circle().fill(st == .success ? Color.green : (st == .pending ? Color.yellow : Color.red)).frame(width: 6, height: 6)
        }
        if checks.isEmpty { IdleItemView(item: .faro, state: state) }
      }
      .help("CI y despliegues de tus proyectos recientes")
    case .shelf:
      let n = state.app?.shelf.items.count ?? 0
      HStack(spacing: 3) {
        Image(systemName: n > 0 ? "tray.full.fill" : "tray").font(.system(size: 11)).foregroundStyle(n > 0 ? Color.mint : .white.opacity(0.5))
        if n > 0 { text("\(n)", color: .mint) }
      }
    case .limit5h: limit(state.claude?.limits?.fiveHour, label: "5h")
    case .limitWeek: limit(state.claude?.limits?.sevenDay, label: "sem")
    case .costToday:
      let cost = state.claude?.costToday ?? 0
      text(cost >= 100 ? "$\(Int(cost))" : String(format: "$%.0f", cost), color: .white.opacity(0.75))
    case .clock:
      TimelineView(.periodic(from: .now, by: 15)) { ctx in
        text(ctx.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()), color: .white.opacity(0.8))
      }
    case .date:
      TimelineView(.periodic(from: .now, by: 60)) { ctx in
        text(ctx.date.formatted(.dateTime.weekday(.abbreviated).day().locale(Locale(identifier: "es_CO"))), color: .white.opacity(0.8))
      }
    case .battery:
      TimelineView(.periodic(from: .now, by: 30)) { _ in
        if let b = Battery.read() {
          HStack(spacing: 3) {
            Image(systemName: b.charging ? "battery.100percent.bolt" : batterySymbol(b.percent))
              .font(.system(size: 11))
              .foregroundStyle(b.percent <= 20 && !b.charging ? .red : .white.opacity(0.8))
            text("\(b.percent)%", color: .white.opacity(0.8))
          }
        }
      }
    case .faro:
      FaroMark(size: 14)
    case .nothing:
      EmptyView()
    }
  }

  @ViewBuilder func limit(_ w: PlanLimits.Window?, label: String) -> some View {
    if let w {
      HStack(spacing: 4) {
        if label == "sem" { Text("sem").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45)) }
        MiniRing(percent: w.percent)
        text("\(Int(w.percent.rounded()))%", color: MiniRing.color(w.percent))
      }
      .help("\(label): \(Int(w.percent.rounded())) %")
    } else {
      IdleItemView(item: .faro, state: state)
    }
  }

  func text(_ s: String, color: Color) -> some View {
    Text(s).font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(color).lineLimit(1)
  }

  func batterySymbol(_ p: Int) -> String {
    switch p {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
  }
}
