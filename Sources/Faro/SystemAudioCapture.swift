import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Audio que suena en el Mac (la otra parte de una videollamada), con ScreenCaptureKit, convertido a 16 kHz mono.
/// Excluye el sonido de la propia Faro. Requiere el permiso «Grabación de pantalla y audio del sistema».
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  var onSamples: (([Float]) -> Void)?
  private var stream: SCStream?
  private let queue = DispatchQueue(label: "dicta.audio-sistema")
  private var converter: AVAudioConverter?
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

  func start() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { throw NSError(domain: "Faro", code: 1) }
    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48000
    config.channelCount = 1
    // Video mínimo: ScreenCaptureKit exige un video; se pide de 2×2 a un cuadro por segundo y se ignora.
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() async {
    try? await stream?.stopCapture()
    stream = nil
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, sampleBuffer.isValid, let desc = sampleBuffer.formatDescription else { return }
    let format = AVAudioFormat(cmAudioFormatDescription: desc)
    if converter == nil || converter?.inputFormat != format { converter = AVAudioConverter(from: format, to: target) }
    try? sampleBuffer.withAudioBufferList { list, _ in
      guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer), let converter else { return }
      let capacity = AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / format.sampleRate + 32)
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
      onSamples?(Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength))))
    }
  }
}
