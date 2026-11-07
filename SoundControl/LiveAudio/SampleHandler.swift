import ReplayKit
import CoreMedia
import Accelerate
import Network

/// Broadcast upload extension. While the user runs a broadcast, iOS hands it
/// the audio other apps are playing. It turns that audio into spectrum bar
/// levels and sends only those levels to Sound Control over the loopback
/// interface. Video frames and microphone audio are ignored, and nothing is
/// uploaded anywhere.
final class SampleHandler: RPBroadcastSampleHandler {
    private let analyzer = SpectrumAnalyzer()
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "LiveAudio.send")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let port = NWEndpoint.Port(rawValue: LiveSpectrum.port) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        connection.start(queue: queue)
        self.connection = connection
    }

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        analyzer.append(sampleBuffer) { [weak self] levels in
            self?.connection?.send(content: LiveSpectrum.encode(levels), completion: .idempotent)
        }
    }
}

/// Mono ring buffer plus a windowed real FFT, producing log-spaced bar levels.
final class SpectrumAnalyzer {
    private let size = 4096
    private let hop = 1024
    private var samples: [Float]
    private var writeIndex = 0
    private var pending = 0
    private let window: [Float]
    private let setup: vDSP_DFT_Setup
    private var sampleRate: Double = 48000

    init() {
        samples = [Float](repeating: 0, count: size)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func append(_ sampleBuffer: CMSampleBuffer, emit: ([Float]) -> Void) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : sampleRate

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        guard let first = buffers.first, let data = first.mData else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(first.mNumberChannels))
        let bytesPerSample = max(1, bits / 8)
        let frames = Int(first.mDataByteSize) / (bytesPerSample * channels)

        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                let index = frame * channels + channel
                if isFloat && bits == 32 {
                    var bitsValue = data.load(fromByteOffset: index * 4, as: UInt32.self)
                    if isBigEndian { bitsValue = bitsValue.byteSwapped }
                    sum += Float(bitPattern: bitsValue)
                } else if bits == 16 {
                    var value = data.load(fromByteOffset: index * 2, as: UInt16.self)
                    if isBigEndian { value = value.byteSwapped }
                    sum += Float(Int16(bitPattern: value)) / 32768
                } else if bits == 32 {
                    var value = data.load(fromByteOffset: index * 4, as: UInt32.self)
                    if isBigEndian { value = value.byteSwapped }
                    sum += Float(Int32(bitPattern: value)) / 2147483648
                } else {
                    return
                }
            }
            samples[writeIndex] = sum / Float(channels)
            writeIndex = (writeIndex + 1) % size
            pending += 1
            if pending >= hop {
                pending = 0
                emit(analyze())
            }
        }
    }

    private func analyze() -> [Float] {
        // Oldest-to-newest copy of the ring, windowed.
        var ordered = Array(samples[writeIndex...] + samples[..<writeIndex])
        vDSP.multiply(ordered, window, result: &ordered)

        let half = size / 2
        var realIn = [Float](repeating: 0, count: half)
        var imagIn = [Float](repeating: 0, count: half)
        for k in 0..<half {
            realIn[k] = ordered[2 * k]
            imagIn[k] = ordered[2 * k + 1]
        }
        var realOut = [Float](repeating: 0, count: half)
        var imagOut = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)

        // Power per bin, scaled so a full-scale sine reads about 0 dB.
        let scale = Float(half) * Float(half)
        var power = [Float](repeating: 0, count: half)
        for k in 1..<half {
            power[k] = (realOut[k] * realOut[k] + imagOut[k] * imagOut[k]) / scale
        }

        let binWidth = sampleRate / Double(size)
        let count = LiveSpectrum.barCount
        var levels = [Float](repeating: 0, count: count)
        for bar in 0..<count {
            let low = LiveSpectrum.frequency(at: Double(bar) / Double(count))
            let high = LiveSpectrum.frequency(at: Double(bar + 1) / Double(count))
            var lowBin = Int((low / binWidth).rounded(.down))
            var highBin = Int((high / binWidth).rounded(.up))
            lowBin = max(1, min(half - 1, lowBin))
            highBin = max(lowBin + 1, min(half, highBin))
            var total: Float = 0
            for k in lowBin..<highBin { total += power[k] }
            let db = 10 * log10(max(total, 1e-12))
            // -65 dBFS ... -5 dBFS mapped to 0...1, then curved like a meter.
            let normalized = max(0, min(1, (db + 65) / 60))
            levels[bar] = pow(normalized, 1.6)
        }
        return levels
    }
}
