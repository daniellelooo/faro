import AppKit
import CoreAudio
import FaroCore
import Observation

/// Volumen por app sin controladores de audio: por cada app con un volumen distinto de 100 % se crea
/// un tap de Core Audio que silencia su salida original y la vuelve a reproducir, con la ganancia elegida, por un
/// dispositivo agregado privado que apunta a la salida actual. Con 100 % no hay tap: el audio va directo.
@MainActor @Observable
final class AppVolumeMixer {
  struct AppAudio: Identifiable, Equatable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var pid: pid_t
    var processObjects: [AudioObjectID]
    var playing: Bool
  }

  private(set) var apps: [AppAudio] = []
  private(set) var gains: [String: Float] = [:]
  private(set) var lastError: String?
  @ObservationIgnored private var engines: [String: TapEngine] = [:]
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var outputUID: String?

  init() {
    gains = (UserDefaults.standard.dictionary(forKey: "volumenPorApp") as? [String: Float]) ?? [:]
  }

  func start() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  func gain(for bundleID: String) -> Float { gains[bundleID] ?? 1 }

  func setGain(_ g: Float, for bundleID: String) {
    let v = min(1.5, max(0, g))
    // Pegarse al 100 % cerca de él, para que sea fácil volver al audio directo.
    gains[bundleID] = abs(v - 1) < 0.03 ? 1 : v
    UserDefaults.standard.set(gains.filter { $0.value != 1 }, forKey: "volumenPorApp")
    if let e = engines[bundleID] { e.gain = gains[bundleID] ?? 1 }
    sync()
  }

  func stopAll() {
    for e in engines.values { e.stop() }
    engines.removeAll()
  }

  // MARK: Apps con audio

  func refresh() {
    let uid = SystemVolume.defaultOutput().flatMap(Self.deviceUID)
    if uid != outputUID {
      // Cambió la salida (por ejemplo, se conectaron los AirPods): los taps se rehacen hacia la nueva.
      outputUID = uid
      stopAll()
    }
    var byApp: [String: AppAudio] = [:]
    for obj in Self.processObjects() {
      guard let pid = Self.pid(of: obj) else { continue }
      let owner = Self.responsiblePID(pid)
      guard let app = NSRunningApplication(processIdentifier: owner), let bundle = app.bundleIdentifier,
        bundle != Bundle.main.bundleIdentifier
      else { continue }
      let playing = Self.isRunningOutput(obj)
      var entry = byApp[bundle] ?? AppAudio(bundleID: bundle, name: app.localizedName ?? bundle, pid: owner, processObjects: [], playing: false)
      entry.processObjects.append(obj)
      entry.playing = entry.playing || playing
      byApp[bundle] = entry
    }
    // Se muestran las que están sonando y las que tienen un volumen guardado.
    let list = byApp.values.filter { $0.playing || gains[$0.bundleID].map { $0 != 1 } == true }
      .sorted { ($0.playing ? 0 : 1, $0.name) < ($1.playing ? 0 : 1, $1.name) }
    if list != apps { apps = list }
    sync()
  }

  /// Crea o quita taps según la ganancia de cada app.
  private func sync() {
    guard let outputUID else { return }
    for app in apps {
      let g = gain(for: app.bundleID)
      if g == 1 {
        engines.removeValue(forKey: app.bundleID)?.stop()
      } else if let e = engines[app.bundleID] {
        if e.processObjects != app.processObjects {
          // La app abrió otro proceso de audio (pasa con los navegadores): se rehace el tap.
          e.stop()
          engines[app.bundleID] = makeEngine(app, outputUID: outputUID, gain: g)
        }
      } else {
        engines[app.bundleID] = makeEngine(app, outputUID: outputUID, gain: g)
      }
    }
    // Apps que se cerraron.
    for (bundle, e) in engines where !apps.contains(where: { $0.bundleID == bundle }) {
      e.stop()
      engines[bundle] = nil
    }
  }

  private func makeEngine(_ app: AppAudio, outputUID: String, gain: Float) -> TapEngine? {
    do {
      let e = try TapEngine(processObjects: app.processObjects, outputUID: outputUID, name: app.name, gain: gain)
      lastError = nil
      return e
    } catch {
      lastError = "No se pudo ajustar el volumen de \(app.name): \(error.localizedDescription). Revisa el permiso de grabación de audio de Faro en Ajustes del Sistema → Privacidad."
      return nil
    }
  }

  // MARK: Core Audio

  static func processObjects() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  static func pid(of obj: AudioObjectID) -> pid_t? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var pid = pid_t(0)
    var size = UInt32(MemoryLayout<pid_t>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr && pid > 0 ? pid : nil
  }

  static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr && v != 0
  }

  static func deviceUID(_ dev: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
    return u.takeRetainedValue() as String
  }

  /// El audio de Chrome o Safari sale de procesos ayudantes; macOS sabe qué app es la "responsable" de cada uno.
  private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
  private static let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
  }()

  static func responsiblePID(_ pid: pid_t) -> pid_t {
    guard let f = responsibleFn else { return pid }
    let r = f(pid)
    return r > 0 ? r : pid
  }
}

/// Un tap con su dispositivo agregado y el bloque de audio que aplica la ganancia.
final class TapEngine: @unchecked Sendable {
  let processObjects: [AudioObjectID]
  /// Se lee desde el hilo de audio; en arm64 escribir un Float es atómico.
  nonisolated(unsafe) var gain: Float
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?

  struct Failure: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) (\(status))" }
  }

  init(processObjects: [AudioObjectID], outputUID: String, name: String, gain: Float) throws {
    self.processObjects = processObjects
    self.gain = gain
    let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
    desc.uuid = UUID()
    desc.muteBehavior = .mutedWhenTapped
    desc.isPrivate = true
    desc.name = "Faro · \(name)"
    var st = AudioHardwareCreateProcessTap(desc, &tapID)
    guard st == noErr else { throw Failure(step: "crear el tap", status: st) }

    let agg: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Faro · \(name)",
      kAudioAggregateDeviceUIDKey: "faro-volumen-\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
    ]
    st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID)
    guard st == noErr else {
      AudioHardwareDestroyProcessTap(tapID)
      throw Failure(step: "crear el dispositivo", status: st)
    }

    st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, _, output, _ in
      TapEngine.copy(input, to: output, gain: self.gain)
    }
    guard st == noErr else {
      stop()
      throw Failure(step: "preparar el audio", status: st)
    }
    st = AudioDeviceStart(aggregateID, procID)
    guard st == noErr else {
      stop()
      throw Failure(step: "arrancar el audio", status: st)
    }
  }

  /// Copia el audio del tap (estéreo) a los primeros canales de la salida, con la ganancia; el resto en silencio.
  static func copy(_ input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outs = UnsafeMutableAudioBufferListPointer(output)
    // Canales de entrada, cada uno como (búfer, canal dentro del búfer, canales del búfer).
    var inChannels: [(UnsafeMutablePointer<Float>, Int, Int, Int)] = []
    for b in ins {
      guard let data = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels > 0 else { continue }
      let n = Int(b.mNumberChannels)
      let frames = Int(b.mDataByteSize) / (4 * n)
      for c in 0..<n { inChannels.append((data, c, n, frames)) }
    }
    var outIndex = 0
    for b in outs {
      guard let data = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels > 0 else { continue }
      let n = Int(b.mNumberChannels)
      let frames = Int(b.mDataByteSize) / (4 * n)
      for c in 0..<n {
        if outIndex < inChannels.count {
          let (src, sc, sn, sframes) = inChannels[outIndex]
          for f in 0..<min(frames, sframes) {
            data[f * n + c] = GainProcessor.process(src[f * sn + sc], gain: gain)
          }
        } else {
          for f in 0..<frames { data[f * n + c] = 0 }
        }
        outIndex += 1
      }
    }
  }

  func stop() {
    if let procID {
      AudioDeviceStop(aggregateID, procID)
      AudioDeviceDestroyIOProcID(aggregateID, procID)
      self.procID = nil
    }
    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
  }

  deinit { stop() }
}
