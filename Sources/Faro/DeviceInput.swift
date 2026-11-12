import AVFoundation
import AudioToolbox
import CoreAudio

/// Graba un micrófono concreto con la unidad de audio de Core Audio (AUHAL), sin pasar por el micrófono por defecto.
/// AVAudioEngine no sirve para esto: al elegirle otro dispositivo avisa un cambio de configuración y vuelve al de
/// por defecto, así que con unos AirPods como entrada del sistema terminaba grabando con ellos igual.
final class DeviceInput: @unchecked Sendable {
  let format: AVAudioFormat
  private var unit: AudioUnit?
  private let onBuffer: (AVAudioPCMBuffer) -> Void
  private let pcm: AVAudioPCMBuffer

  enum Failure: Error { case component, status(OSStatus) }

  init(device: AudioDeviceID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
    self.onBuffer = onBuffer
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &desc) else { throw Failure.component }
    var created: AudioUnit?
    try Self.check(AudioComponentInstanceNew(component, &created))
    guard let unit = created else { throw Failure.component }
    self.unit = unit
    // Bus 1 es la entrada (micrófono) y bus 0 la salida: solo se usa la entrada.
    var on: UInt32 = 1
    var off: UInt32 = 0
    try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
    try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4))
    var id = device
    try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
      UInt32(MemoryLayout<AudioDeviceID>.size)))
    // Formato del micrófono (lado de entrada del bus 1); se pide mono en Float32 a esa misma frecuencia.
    var hw = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size))
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate, channels: 1, interleaved: false),
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
    else { throw Failure.component }
    self.format = format
    self.pcm = pcm
    var client = format.streamDescription.pointee
    try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
    var callback = AURenderCallbackStruct(inputProc: { refcon, flags, time, bus, frames, _ in
      Unmanaged<DeviceInput>.fromOpaque(refcon).takeUnretainedValue().render(flags, time, bus, frames)
    }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
      UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
    try Self.check(AudioUnitInitialize(unit))
    try Self.check(AudioOutputUnitStart(unit))
  }

  private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32, _ frames: UInt32) -> OSStatus {
    guard let unit, frames <= pcm.frameCapacity else { return noErr }
    pcm.frameLength = frames
    let list = pcm.mutableAudioBufferList
    list.pointee.mBuffers.mDataByteSize = frames * 4
    let status = AudioUnitRender(unit, flags, time, bus, frames, list)
    if status == noErr { onBuffer(pcm) }
    return status
  }

  func stop() {
    guard let unit else { return }
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
    self.unit = nil
  }

  private static func check(_ status: OSStatus) throws {
    if status != noErr { throw Failure.status(status) }
  }
}
