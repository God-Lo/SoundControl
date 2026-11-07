import Foundation

/// Shared by the app and the LiveAudio broadcast extension: the bar layout and
/// the packet format used to pass spectrum levels between them.
///
/// The extension receives the phone's playback audio from ReplayKit while a
/// broadcast is running, computes bar levels, and sends them to the app over
/// UDP on the loopback interface. No audio leaves the device or the extension;
/// only the 72 bar levels reach the app.
enum LiveSpectrum {
    static let port: UInt16 = 51723
    static let barCount = 72
    static let magic: [UInt8] = Array("SCLV".utf8)

    /// Frequency (Hz) at horizontal position `x` (0...1). Matches the EQ handle
    /// layout: the five EQ bands (400 Hz ... 16 kHz, evenly spaced on a log
    /// axis) sit at the centers of five equal columns, so 400 Hz is at x = 0.1
    /// and 16 kHz at x = 0.9. The lows (40-400 Hz) fill the first tenth and
    /// 16-20 kHz the last tenth.
    static func frequency(at x: Double) -> Double {
        if x <= 0.1 { return 40 * pow(10, x / 0.1) }
        if x >= 0.9 { return 16000 * pow(20000.0 / 16000.0, (x - 0.9) / 0.1) }
        return 400 * pow(10, 0.4 * (x - 0.1) / 0.2)
    }

    /// Encodes levels (0...1) as `magic | count | count bytes`.
    static func encode(_ levels: [Float]) -> Data {
        var bytes = magic
        bytes.append(UInt8(levels.count))
        bytes += levels.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        return Data(bytes)
    }

    static func decode(_ data: Data) -> [Float]? {
        let bytes = [UInt8](data)
        guard bytes.count > magic.count, Array(bytes.prefix(magic.count)) == magic else { return nil }
        let count = Int(bytes[magic.count])
        guard count > 0, bytes.count == magic.count + 1 + count else { return nil }
        return bytes.suffix(count).map { Float($0) / 255 }
    }
}
