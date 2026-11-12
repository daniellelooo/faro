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
  /// Mayor nivel recibido en la grabación: si queda en cero el micrófono no mandó nada (ni ruido de fondo).
  private(set) var peak: Float = 0
  /// Trozos de audio recibidos en la grabación.
  private(set) var chunks = 0
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
    stopObserving()
    engine = AVAudioEngine()
    try connect()
    isRecording = true
    // Si el micrófono cambia a mitad de grabación (AirPods que pasan a modo llamada, otro micrófono por defecto),
    // el sistema detiene el motor: se vuelve a conectar con el formato nuevo y se sigue grabando.
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      guard let self, self.isRecording else { return }
      self.engine.stop()
      try? self.connect()
    }
  }

  private func connect() throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
    converter = AVAudioConverter(from: format, to: target)
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
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    isRecording = false
    level = 0
    lock.lock()
    defer { lock.unlock() }
    return buffer
  }

  private func append(_ pcm: AVAudioPCMBuffer) {
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

/// Nombre del micrófono que usa el sistema, para decir cuál falló.
enum MicInfo {
  static var defaultInputName: String? {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    addr.mSelector = kAudioObjectPropertyName
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
    return name.takeRetainedValue() as String
  }
}
