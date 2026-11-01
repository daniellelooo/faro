import AppKit
import FaroCore

// Subcomandos que Claude Code ejecuta (barra de estado y hooks): corren y terminan sin abrir la app.
if CommandLine.arguments.contains(ClaudeIntegration.hookFlag) {
  ClaudeBridge.handleHook()
  exit(0)
}
if CommandLine.arguments.contains(ClaudeIntegration.statusFlag) {
  ClaudeBridge.handleStatusLine()
  exit(0)
}

// `--probar-limites`: consulta los límites con el token guardado e imprime el resultado (sin mostrar el token).
if CommandLine.arguments.contains("--probar-limites") {
  let done = DispatchSemaphore(value: 0)
  Task.detached {
    guard let token = KeychainStore.read(service: PlanUsageClient.tokenService) else {
      print("sin token")
      done.signal()
      return
    }
    do {
      let l = try await PlanUsageClient.fetch(token: token)
      print("5h:", l.fiveHour?.percent ?? -1, "semana:", l.sevenDay?.percent ?? -1, "endpoint de uso prohibido:", PlanUsageClient.usageEndpointForbidden)
    } catch {
      print("error:", error)
    }
    done.signal()
  }
  done.wait()
  exit(0)
}

// Antes de crear cualquier almacén: mover los datos de cuando la app se llamaba Dicta.
Migration.moveLegacyData()

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  withExtendedLifetime(delegate) { app.run() }
}
