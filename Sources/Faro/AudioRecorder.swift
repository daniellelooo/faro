import AVFoundation
import CoreAudio
import Foundation

/// Graba el micrófono y entrega muestras a 16 kHz mono, más el nivel para el indicador.
final class AudioRecorder: @unchecked Sendable {
  static let sampleRate = 16000
  /// Un motor nuevo en cada grabación: con unos AirPods, al pasar a modo llamada cambia el formato del micrófono y un
  /// motor reusado después de ese cambio puede quedar corriendo sin entregar audio.
  private var engine = AVAudioEngine()
  private var configObserver: NSObjectProtocol?
  /// Grabación directa del micrófono del Mac cuando la entrada del sistema son audífonos Bluetooth.
  private var deviceInput: DeviceInput?
  /// Mayor nivel recibido en la grabación: si queda en cero el micrófono no mandó nada (ni ruido de fondo).
  private(set) var peak: Float = 0
  /// Trozos de audio recibidos en la grabación.
  private(set) var chunks = 0
  /// Formato del micrófono en cada conexión de la grabación ("24000 Hz 1 canal"); más de uno si cambió a mitad.
  private(set) var formats: [String] = []
  private let lock = NSLock()
  private var buffer: [Float] = []
  private var converter: AVAudioConverter?
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
  /// Nivel RMS reciente (0…1), leído por el indicador.
  private(set) var level: Float = 0
  private(set) var isRecording = false
  /// El dictado necesita todo el audio al soltar fn; las reuniones no (van a disco y a la transcripción por tramos).
  var keepsAudio = true
  /// Recibe cada trozo convertido a 16 kHz, en el hilo de audio (para transcribir mientras se habla).
  var onSamples: (([Float]) -> Void)?

  func start() throws {
    lock.lock()
    buffer.removeAll(keepingCapacity: true)
    lock.unlock()
    peak = 0
    chunks = 0
    formats = []
    stopObserving()
    converter = nil
    if let mic = MicInfo.preferredInput() {
      let input = try DeviceInput(device: mic) { [weak self] pcm in self?.append(pcm) }
      deviceInput = input
      formats.append("\(MicInfo.name(of: mic) ?? "?") \(Int(input.format.sampleRate)) Hz")
      isRecording = true
      return
    }
    engine = AVAudioEngine()
    try connect()
    isRecording = true
    // Si el micrófono cambia a mitad de grabación (AirPods que pasan a modo llamada, otro micrófono por defecto),
    // el sistema detiene el motor: se vuelve a conectar con el formato nuevo y se sigue grabando.
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      // Solo si el sistema detuvo el motor; algunos avisos llegan con el motor andando y no hace falta reconectar.
      guard let self, self.isRecording, !self.engine.isRunning else { return }
      try? self.connect()
    }
  }

  private func connect() throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
    converter = nil
    formats.append("\(MicInfo.name(of: MicInfo.currentDevice(of: input)) ?? "?") \(Int(format.sampleRate)) Hz")
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcm, _ in
      self?.append(pcm)
    }
    engine.prepare()
    try engine.start()
  }

  private func stopObserving() {
    if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    configObserver = nil
  }

  enum RecorderError: Error { case noInput }

  /// Detiene la grabación y devuelve todo lo grabado.
  func stop() -> [Float] {
    stopObserving()
    if let deviceInput {
      deviceInput.stop()
      self.deviceInput = nil
    } else {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    isRecording = false
    level = 0
    lock.lock()
    defer { lock.unlock() }
    return buffer
  }

  private func append(_ pcm: AVAudioPCMBuffer) {
    if converter?.inputFormat != pcm.format { converter = AVAudioConverter(from: pcm.format, to: target) }
    guard let converter else { return }
    let ratio = target.sampleRate / pcm.format.sampleRate
    let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 32)
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed {
        status.pointee = .noDataNow
        return nil
      }
      fed = true
      status.pointee = .haveData
      return pcm
    }
    guard error == nil, let ch = out.floatChannelData?[0] else { return }
    let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    var sum: Float = 0
    for s in samples { sum += s * s }
    let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
    if keepsAudio {
      lock.lock()
      buffer.append(contentsOf: samples)
      lock.unlock()
    }
    onSamples?(samples)
    level = min(1, rms * 8)
    chunks += 1
    peak = max(peak, samples.reduce(0) { max($0, abs($1)) })
  }
}

/// Qué micrófono usar. Con audífonos Bluetooth (AirPods) como entrada del sistema se prefiere el del Mac: al usar su
/// micrófono los audífonos pasan a modo llamada, el audio llega con mucha menos calidad (Whisper inventa palabras) y la
/// música baja de calidad mientras se dicta.
enum MicInfo {
  static let preferBuiltInKey = "microfonoDelMacConBluetooth"

  static var preferBuiltIn: Bool { UserDefaults.standard.object(forKey: preferBuiltInKey) as? Bool ?? true }

  /// El micrófono del Mac si la entrada del sistema es Bluetooth y la opción está activa; nil para usar la del sistema.
  static func preferredInput() -> AudioDeviceID? {
    guard preferBuiltIn, let current = defaultInput, isBluetooth(current) else { return nil }
    return inputDevices().first { transport(of: $0) == kAudioDeviceTransportTypeBuiltIn && isAlive($0) }
  }

  static var defaultInput: AudioDeviceID? {
    var id = AudioDeviceID(0)
    return get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id) ? id : nil
  }

  static var defaultInputName: String? { defaultInput.flatMap(name(of:)) }

  static func currentDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
    guard let unit = input.audioUnit else { return nil }
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr
    else { return nil }
    return id
  }

  static func name(of id: AudioDeviceID?) -> String? {
    guard let id else { return nil }
    var name: Unmanaged<CFString>?
    guard get(id, kAudioObjectPropertyName, &name), let name else { return nil }
    return name.takeRetainedValue() as String
  }

  private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = transport(of: id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
  }

  private static func transport(of id: AudioDeviceID) -> UInt32 {
    var t = UInt32(0)
    return get(id, kAudioDevicePropertyTransportType, &t) ? t : 0
  }

  private static func isAlive(_ id: AudioDeviceID) -> Bool {
    var alive = UInt32(0)
    return get(id, kAudioDevicePropertyDeviceIsAlive, &alive) && alive != 0
  }

  private static func inputDevices() -> [AudioDeviceID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { id in
      var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
      var s = UInt32(0)
      return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr && s > 0
    }
  }

  private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
  }
}
