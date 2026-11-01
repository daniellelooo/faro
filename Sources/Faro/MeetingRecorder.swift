import AVFoundation
import FaroCore
import Foundation

/// Graba una reunión: micrófono (y, en videollamadas, el audio del Mac), mezclado a 16 kHz mono.
/// El audio va a un archivo AAC y a la transcripción por tramos al mismo tiempo.
final class MeetingRecorder: @unchecked Sendable {
  let mic = AudioRecorder()
  let system = SystemAudioCapture()
  var onMixed: (([Float]) -> Void)?
  private let lock = NSLock()
  private var systemQueue: [Float] = []
  private var file: AVAudioFile?
  private let writeQueue = DispatchQueue(label: "dicta.reunion.archivo")
  private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
  private(set) var usesSystemAudio = false
  private(set) var isPaused = false

  var level: Float { mic.level }

  func start(audioURL: URL, includeSystemAudio: Bool) async throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
    ]
    file = try AVAudioFile(forWriting: audioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    usesSystemAudio = false
    if includeSystemAudio {
      system.onSamples = { [weak self] s in
        guard let self, !self.isPaused else { return }
        self.lock.withLock { self.systemQueue.append(contentsOf: s) }
      }
      do {
        try await system.start()
        usesSystemAudio = true
      } catch {
        // Sin el permiso de grabación de pantalla se sigue solo con el micrófono.
        system.onSamples = nil
      }
    }
    mic.keepsAudio = false
    mic.onSamples = { [weak self] s in self?.mix(s) }
    try mic.start()
  }

  /// En pausa se apaga el micrófono (se va el punto naranja) y no se escribe ni se transcribe nada.
  func pause() {
    guard !isPaused else { return }
    isPaused = true
    mic.onSamples = nil
    _ = mic.stop()
  }

  func resume() throws {
    guard isPaused else { return }
    lock.withLock { systemQueue.removeAll() }
    mic.onSamples = { [weak self] s in self?.mix(s) }
    try mic.start()
    isPaused = false
  }

  /// Mezcla cada trozo del micrófono con la misma cantidad de audio del Mac (o silencio si no llegó).
  private func mix(_ micSamples: [Float]) {
    if isPaused { return }
    var out = micSamples
    lock.withLock {
      let n = min(systemQueue.count, out.count)
      for i in 0..<n { out[i] = max(-1, min(1, out[i] * 0.8 + systemQueue[i] * 0.8)) }
      systemQueue.removeFirst(n)
      // Si el audio del Mac se adelanta más de 2 s (deriva de relojes), se descarta lo viejo.
      if systemQueue.count > 32000 { systemQueue.removeFirst(systemQueue.count - 16000) }
    }
    onMixed?(out)
    writeQueue.async { [weak self] in
      guard let self, let file = self.file,
        let buf = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(out.count))
      else { return }
      buf.frameLength = AVAudioFrameCount(out.count)
      out.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: out.count) }
      try? file.write(from: buf)
    }
  }

  func stop() async {
    isPaused = false
    mic.onSamples = nil
    _ = mic.stop()
    if usesSystemAudio { await system.stop() }
    system.onSamples = nil
    writeQueue.sync { file = nil }
  }
}
