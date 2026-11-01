import FaroCore
import SwiftUI

/// Página IA de la ventana: límites del plan, valor a precio de API y conexión con Claude Code.
struct AIView: View {
  let app: AppDelegate
  @Bindable var claude: ClaudeMonitor
  @State private var message: String?
  @State private var confirmConnect = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        PaneHeader(title: "IA", subtitle: "Tus límites de Claude, cuánto costaría tu uso por API y en qué proyectos trabajas.")

        if !claude.connected {
          Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 12) {
                Image(systemName: "sparkle").font(.title2).foregroundStyle(Color.claude)
                VStack(alignment: .leading, spacing: 2) {
                  Text("Conectar con Claude Code").font(.title3.weight(.semibold))
                  Text("Para ver tus límites al día y avisos cuando Claude termina o necesita tu permiso.")
                    .font(.callout).foregroundStyle(.secondary)
                }
              }
              Text("Faro agrega una barra de estado y unos hooks a ~/.claude/settings.json. Antes guarda una copia de respaldo. Tu barra de estado y tus hooks actuales se conservan. Se puede desconectar cuando quieras.")
                .font(.caption).foregroundStyle(.secondary)
              Button("Conectar con Claude Code") { confirmConnect = true }
                .buttonStyle(.borderedProminent)
            }
          }
          .confirmationDialog("¿Conectar Faro con Claude Code?", isPresented: $confirmConnect) {
            Button("Conectar") {
              do {
                try claude.connect()
                message = "Conectado. Los límites aparecen después de tu próximo mensaje en Claude Code."
              } catch {
                message = "No se pudo conectar: \(error.localizedDescription)"
              }
            }
          } message: {
            Text("Se modifica ~/.claude/settings.json (con copia de respaldo).")
          }
        }

        HStack(alignment: .top, spacing: 14) {
          Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
              Label("Límites del plan", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
              if let l = claude.limits {
                LimitRow(title: "Ventana de 5 horas", window: l.fiveHour)
                LimitRow(title: "Semana", window: l.sevenDay)
                ForEach(l.models) { LimitRow(title: "Semana · \($0.title)", window: $0) }
                Text("\(l.sourceLabel) · actualizado \(l.fetchedAt.formatted(.relative(presentation: .named)))")
                  .font(.caption).foregroundStyle(.secondary)
              } else if !claude.hasLimitsToken {
                LimitsConnectView(claude: claude)
              } else {
                Text(claude.limitsProblem ?? "Consultando tu cuenta…").foregroundStyle(.secondary)
              }
              if claude.hasLimitsToken {
                if let p = claude.limitsProblem, claude.limits != nil { Text(p).font(.caption).foregroundStyle(.orange) }
                Button("Quitar el acceso a los límites", role: .destructive) { claude.removeLimitsToken() }
                  .buttonStyle(.link).font(.caption)
              }
            }
          }
          Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
              Label("Si pagaras por API", systemImage: "dollarsign.circle").font(.headline)
              if claude.report == nil {
                HStack {
                  ProgressView().controlSize(.small)
                  Text("Leyendo tu historial de Claude Code (la primera vez tarda un par de minutos)…").font(.callout).foregroundStyle(.secondary)
                }
              } else {
                BigCost(label: "Hoy", value: claude.costToday)
                BigCost(label: "Últimos 7 días", value: claude.costWeek)
                BigCost(label: "Este mes", value: claude.costMonth)
                Text("Estimado con los precios de lista de la API a partir de los registros de Claude Code en este Mac.")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }

        ProjectsSection(claude: claude)

        if let report = claude.report {
          VStack(alignment: .leading, spacing: 8) {
            Text("Por modelo (todo el historial)").font(.headline)
            Card {
              VStack(spacing: 10) {
                ForEach(report.byModel.filter { $0.value.cost > 0.005 }.sorted { $0.value.cost > $1.value.cost }, id: \.key) { model, u in
                  HStack {
                    Text(model).font(.body.monospaced())
                    Spacer()
                    Text(String(format: "%.1f M tokens", Double(u.totalTokens) / 1e6)).foregroundStyle(.secondary).monospacedDigit()
                    Text(u.cost.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                      .font(.body.weight(.semibold)).monospacedDigit().frame(width: 90, alignment: .trailing)
                  }
                }
              }
            }
          }
        }

        if claude.connected {
          HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Conectado con Claude Code")
            Spacer()
            Button("Desconectar") {
              do {
                try claude.disconnect()
                message = "Desconectado. Tu configuración anterior quedó restaurada."
              } catch { message = "No se pudo desconectar: \(error.localizedDescription)" }
            }
          }
          .font(.callout)
        }
        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
      }
      .padding(28)
      .frame(maxWidth: 880, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

struct LimitRow: View {
  let title: String
  let window: PlanLimits.Window?
  var body: some View {
    let used = window?.percent ?? 0
    let color: Color = used >= 90 ? .red : (used >= 70 ? .orange : Color.claude)
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
        Spacer()
        Text(window == nil ? "–" : "\(Int(used.rounded())) %").font(.title3.weight(.bold)).monospacedDigit()
      }
      ProgressView(value: min(100, used), total: 100).tint(color)
      if let r = window?.resetsAt {
        Text("Se reinicia \(r.formatted(.relative(presentation: .named))) (\(r.formatted(date: .omitted, time: .shortened)))")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct BigCost: View {
  let label: String
  let value: Double
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 100 ? 0 : 2))))
        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
    }
  }
}

extension PlanLimits {
  var sourceLabel: String {
    switch source {
    case .account: return "De tu cuenta de Claude"
    case .statusLine: return "De la barra de estado de Claude Code"
    case .desktop: return "De la app de escritorio de Claude"
    }
  }
}

/// Pasos para que Faro lea los límites de la cuenta con un token propio de solo lectura de uso.
struct LimitsConnectView: View {
  @Bindable var claude: ClaudeMonitor
  @State private var token = ""
  @State private var checking = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("La app de escritorio de Claude no comparte tus límites con otras apps. Faro los consulta a tu cuenta con un token propio, igual que hace la app de escritorio.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 8) {
        Text("1").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(Circle().fill(Theme.violet.opacity(0.2)))
        VStack(alignment: .leading, spacing: 6) {
          Text("Genera el token en la Terminal (se abre el navegador para autorizar).").font(.callout)
          Button("Abrir Terminal con claude setup-token") { LimitsConnectView.openSetupToken() }
        }
      }
      HStack(alignment: .top, spacing: 8) {
        Text("2").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(Circle().fill(Theme.violet.opacity(0.2)))
        VStack(alignment: .leading, spacing: 6) {
          Text("Pega aquí el token que imprime (empieza por sk-ant-). Se guarda en el Llavero.").font(.callout)
          HStack {
            SecureField("sk-ant-…", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            Button(checking ? "Comprobando…" : "Guardar") {
              checking = true
              Task {
                error = await claude.saveLimitsToken(token)
                checking = false
                if error == nil { token = "" }
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(token.isEmpty || checking)
          }
          Button("Usar el token que copiaste") {
            guard let copied = NSPasteboard.general.string(forType: .string) else {
              error = "El portapapeles está vacío. Copia el token en la Terminal."
              return
            }
            checking = true
            Task {
              error = await claude.saveLimitsToken(copied)
              checking = false
            }
          }
          .disabled(checking)
          if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
      }
    }
  }

  /// Abre una ventana de Terminal que corre `claude setup-token`. El token se queda en esa ventana: Faro no lo lee de ahí.
  static func openSetupToken() {
    let candidates = ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    let claude = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("faro-setup-token.command")
    let body = "#!/bin/sh\nclear\necho 'Faro: autoriza en el navegador y copia el token que aparece al final.'\necho\n'\(claude)' setup-token\n"
    try? body.write(to: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
      configuration: NSWorkspace.OpenConfiguration())
  }
}
