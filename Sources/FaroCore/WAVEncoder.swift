import Foundation

public enum WAVEncoder {
  /// PCM de 16 bits, mono.
  public static func encode(samples: [Float], sampleRate: Int) -> Data {
    var data = Data()
    let dataSize = samples.count * 2
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1)
    u16(1)
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 2))
    u16(2)
    u16(16)
    data.append(contentsOf: Array("data".utf8))
    u32(UInt32(dataSize))
    data.reserveCapacity(data.count + dataSize)
    for s in samples {
      let v = Int16(max(-1, min(1, s)) * 32767)
      u16(UInt16(bitPattern: v))
    }
    return data
  }
}
