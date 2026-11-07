import Foundation
import ExternalAccessory

final class ExternalAccessoryTransport: NSObject, StreamDelegate {
    let accessory: EAAccessory
    private let session: EASession
    private var input: InputStream? { session.inputStream }
    private var output: OutputStream? { session.outputStream }
    private var inputBuffer = Data()
    private var outputQueue: [Data] = []
    private var outputOffset = 0
    private var didReportOpen = false

    var onBytes: ((Data) -> Void)?
    var onState: ((Bool, String?) -> Void)?

    init(accessory: EAAccessory, session: EASession) {
        self.accessory = accessory
        self.session = session
        super.init()
    }

    func open() {
        guard let input, let output else {
            onState?(false, "Accessory streams are unavailable.")
            return
        }
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        input.open()
        output.open()
    }

    func close() {
        input?.close()
        output?.close()
        input?.remove(from: .main, forMode: .common)
        output?.remove(from: .main, forMode: .common)
        didReportOpen = false
    }

    func write(_ data: Data) {
        outputQueue.append(data)
        flushOutput()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if !didReportOpen && input?.streamStatus == .open && output?.streamStatus == .open {
                didReportOpen = true
                onState?(true, nil)
            }
        case .hasBytesAvailable:
            readAvailableBytes()
        case .hasSpaceAvailable:
            flushOutput()
        case .errorOccurred:
            onState?(false, aStream.streamError?.localizedDescription ?? "Accessory stream failed.")
        case .endEncountered:
            onState?(false, "Accessory stream ended.")
        default:
            break
        }
    }

    private func readAvailableBytes() {
        guard let input else { return }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            inputBuffer.append(contentsOf: buffer[..<count])
        }
        if !inputBuffer.isEmpty {
            let data = inputBuffer
            inputBuffer.removeAll(keepingCapacity: true)
            onBytes?(data)
        }
    }

    private func flushOutput() {
        guard let output, output.streamStatus == .open else { return }
        while !outputQueue.isEmpty && output.hasSpaceAvailable {
            let data = outputQueue[0]
            let remaining = data.count - outputOffset
            let written = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base.advanced(by: outputOffset), maxLength: remaining)
            }
            guard written > 0 else { return }
            outputOffset += written
            if outputOffset == data.count {
                outputQueue.removeFirst()
                outputOffset = 0
            }
        }
    }
}
