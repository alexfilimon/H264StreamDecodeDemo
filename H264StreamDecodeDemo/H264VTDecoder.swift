import AVFoundation
import UIKit
import VideoToolbox

public protocol H264VTDecoderDelegate: AnyObject {
    func decodeOutput(pixelBuffer: CVPixelBuffer)
    func decodeOutput(error: H264VTDecoderError)
}

public enum H264VTDecoderError: Error {
    case decompressionSessionCreate
    case blockBufferCreateWithMemoryBlock
    case sampleBufferCreateReady
    case decompressionSessionDecodeFrame
}

/// VideoToolbox decoder
///
/// To property working with decoder need:
/// 1. Call `setup(formatDescription:)` to initialize vtDecompressionSession
/// 2. Call `decode(nalu:completion:)` to decode frames
/// 3. Invalidate session when decoding ends
///
final class H264VTDecoder {

    // MARK: - Properties

    weak var delegate: H264VTDecoderDelegate?

    // MARK: - Private Properties

    private let flagIn: VTDecodeFrameFlags = [
        ._EnableAsynchronousDecompression,
        ._EnableTemporalProcessing
    ]
    private let attributes: [NSString: AnyObject] = [
        kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as AnyObject,
        // swiftlint:disable compiler_protocol_init
        kCVPixelBufferOpenGLESCompatibilityKey: NSNumber(booleanLiteral: true)
        // swiftlint:enable compiler_protocol_init
    ]
    private var invalidateSession = false
    private var formatDescription: CMVideoFormatDescription?
    private var callback: VTDecompressionOutputCallback = { (
        // swiftlint:disable closure_parameter_position
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        _: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVBuffer?,
        presentationTimeStamp: CMTime,
        duration: CMTime
        // swiftlint:enable closure_parameter_position
    ) in
        guard let decompressionOutputRefCon else { return }
        let decoder: H264VTDecoder = Unmanaged<H264VTDecoder>.fromOpaque(decompressionOutputRefCon)
            .takeUnretainedValue()
        decoder.didOutputForSession(
            status,
            infoFlags: infoFlags,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration
        )
    }

    private var session: VTDecompressionSession?

    // MARK: - Deinitialization

    deinit {
        invalidate()
    }

    // MARK: - Methods

    func setup(formatDescription: CMFormatDescription) throws {
        self.formatDescription = formatDescription
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary?,
            outputCallback: &record,
            decompressionSessionOut: &session
        )
        guard status == .zero else {
            throw H264VTDecoderError.decompressionSessionCreate
        }
    }

    func decode(nalu: H264NALU) {
        var normalizedBytes = bytesInsertedSizeBefore(nalu.bytes)
        let normalizedBytesSize = normalizedBytes.count
        var blockBuffer: CMBlockBuffer?
        let resultCreateBuffer = normalizedBytes.withUnsafeMutableBytes { unsafeMutableRawBufferPointer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: unsafeMutableRawBufferPointer.baseAddress,
                blockLength: normalizedBytesSize,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: normalizedBytesSize,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            )
        }

        guard
            let blockBuffer,
            resultCreateBuffer == .zero
        else {
            delegate?.decodeOutput(error: .blockBufferCreateWithMemoryBlock)
            return
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray: [Int] = [normalizedBytes.count]
        let sampleBufferCreateStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleBufferCreateStatus == .zero else {
            delegate?.decodeOutput(error: .sampleBufferCreateReady)
            return
        }

        guard
            let sampleBuff = sampleBuffer,
            let session
        else {
            delegate?.decodeOutput(error: .decompressionSessionCreate)
            return
        }

        var flagOut: VTDecodeInfoFlags = []
        let decompressionSessionDecodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuff,
            flags: flagIn,
            frameRefcon: nil,
            infoFlagsOut: &flagOut
        )
        guard decompressionSessionDecodeStatus == .zero else {
            delegate?.decodeOutput(error: .decompressionSessionDecodeFrame)
            return
        }
    }

    func invalidate() {
        guard let session else { return }
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Private Methods

    /// Add four bytes of buffer size before buffer
    private func bytesInsertedSizeBefore(_ bytes: [UInt8]) -> [UInt8] {
        var newBytes = bytes
        let byteArray = withUnsafeBytes(of: UInt32(bytes.count).bigEndian, [UInt8].init)
        newBytes.insert(contentsOf: byteArray, at: 0)
        return newBytes
    }

    private func didOutputForSession(
        _ status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) {
        guard let imageBuffer else {
            delegate?.decodeOutput(error: .decompressionSessionDecodeFrame)
            return
        }

        delegate?.decodeOutput(pixelBuffer: imageBuffer)
    }

}
