import AVFoundation
import Foundation

/// Graba el micrófono y entrega muestras a 16 kHz mono, más el nivel para el indicador.
final class AudioRecorder: @unchecked Sendable {
  static let sampleRate = 16000
  private let engine = AVAudioEngine()
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
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    converter = AVAudioConverter(from: format, to: target)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcm, _ in
      self?.append(pcm)
    }
    engine.prepare()
    try engine.start()
    isRecording = true
  }

  /// Detiene la grabación y devuelve todo lo grabado.
  func stop() -> [Float] {
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
  }
}
