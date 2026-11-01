import AudioToolbox
import CoreAudio
import Foundation

/// Volumen y silencio de la salida de audio actual (lo que mueven las teclas de volumen).
enum SystemVolume {
  static func defaultOutput() -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
  }

  private static func volumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
  }

  private static func muteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
  }

  /// nil si la salida no deja cambiar el volumen (por ejemplo, algunas por HDMI).
  static var volume: Float? {
    guard let dev = defaultOutput() else { return nil }
    var addr = volumeAddress()
    guard AudioObjectHasProperty(dev, &addr) else { return nil }
    var v = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioHardwareServiceGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
  }

  static func setVolume(_ value: Float) {
    guard let dev = defaultOutput() else { return }
    var addr = volumeAddress()
    var v = Float32(min(1, max(0, value)))
    _ = AudioHardwareServiceSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
  }

  static var isMuted: Bool {
    guard let dev = defaultOutput() else { return false }
    var addr = muteAddress()
    guard AudioObjectHasProperty(dev, &addr) else { return false }
    var m = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr && m != 0
  }

  static func setMuted(_ muted: Bool) {
    guard let dev = defaultOutput() else { return }
    var addr = muteAddress()
    var m = UInt32(muted ? 1 : 0)
    _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
  }

  static var outputName: String {
    guard let dev = defaultOutput() else { return "" }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "" }
    return n.takeRetainedValue() as String
  }
}
