import FaroCore
import Foundation
let now = Date()
for pass in 1...2 {
  let t0 = Date()
  let r = UsageCache().refresh()
  let month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now))!
  print(String(format: "Pasada %d: %.2f s · hoy $%.2f · 7 días $%.2f · mes $%.2f", pass, Date().timeIntervalSince(t0),
    r.cost(since: now), r.cost(since: now.addingTimeInterval(-6 * 86400)), r.cost(since: month)))
}
