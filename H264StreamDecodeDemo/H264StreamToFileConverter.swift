import AVFoundation
import Combine
import CoreVideo

public enum H264StreamToFileConverterError: Error {
    case unableToStartWriting
    case unknownWriterState
    case avFoundationError(Error?)
    case unableToGetFormatDescription
    case vtDecoderError
    case wrongStream
}

/// Class for converting h264 stream to file
public final class H264StreamToFileConverter: H264VTDecoderDelegate {

    // MARK: - Nested Types

    public struct ImageSize {
        public let width: Int
        public let height: Int

        public init(
            width: Int,
            height: Int
        ) {
            self.width = width
            self.height = height
        }
    }

    public struct InputFileConfig {
        public let frameRate: Int
        public let imageSize: ImageSize

        public init(
            frameRate: Int,
            imageSize: ImageSize
        ) {
            self.frameRate = frameRate
            self.imageSize = imageSize
        }
    }

    public struct OutputFileConfig {
        public let folderURL: URL

        public init(folderURL: URL) {
            self.folderURL = folderURL
        }

        func getFileURL(
            fileName: String,
            fileExtension: String?
        ) -> URL {
            var url = folderURL
                .appendingPathComponent(fileName)
            if let fileExtension {
                url.appendPathExtension(fileExtension)
            }
            return url
        }
    }

    private struct LockedBuffer {
        let buffer: CVPixelBuffer
        var isLocked: Bool
    }

    // MARK: - Constants

    private enum Constants {
        static let timeScale: Int32 = 1_000_000
    }

    // MARK: - Properties

    private let inputFileConfig: InputFileConfig
    private let outputFileConfig: OutputFileConfig
    private let naluParser: H264NALUParser
    private let vtDecoder: H264VTDecoder

    private var completionSubject = PassthroughSubject<URL, H264StreamToFileConverterError>()

    private let assetWriter: AVAssetWriter
    private var assetWriterInput: AVAssetWriterInput?
    private var assetWriterInputAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let workingQueue = DispatchQueue(label: "h264_stream_to_file_converter_working_queue")

    private var currentIndex = 0
    private var spsPpsWasSet = false
    private var isFinished = false
    private var naluParserFinished = false
    private var decodeRequestsEnded = false

    private var spsBytes: [UInt8] = []
    private var ppsBytes: [UInt8] = []

    private var cvPixelBuffersQueue: [LockedBuffer] = []

    private var numberOfActiveRequests = 0

    // MARK: - Initialization & Deinitialization

    public init(
        inputFileConfig: InputFileConfig,
        outputFileConfig: OutputFileConfig,
        naluParser: H264NALUParser
    ) throws {
        self.inputFileConfig = inputFileConfig
        self.outputFileConfig = outputFileConfig
        self.naluParser = naluParser

        assetWriter = try .init(
            outputURL: outputFileConfig.getFileURL(
                fileName: UUID().uuidString,
                fileExtension: "mp4"
            ),
            fileType: .mp4
        )
        vtDecoder = .init()
        vtDecoder.delegate = self
    }

    deinit {
        unlockBuffersIfNeeded()
    }

    // MARK: - Methods

    /// Method for starting converting. Completion may be called in internal queue.
    /// Better dispatch.async on completion.
    /// Before start file in `outputFileURL` must not exists.
    public func convert() -> AnyPublisher<URL, H264StreamToFileConverterError> {
        workingQueue.async {
            self.startProcessing()
        }

        return completionSubject.eraseToAnyPublisher()
    }

    // MARK: - H264VTDecoderDelegate

    public func decodeOutput(pixelBuffer: CVPixelBuffer) {
        // we need to lock address to keep it in memory
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

        workingQueue.async {
            self.numberOfActiveRequests -= 1
            self.cvPixelBuffersQueue.append(
                .init(
                    buffer: pixelBuffer,
                    isLocked: true
                )
            )
        }
    }

    public func decodeOutput(error: H264VTDecoderError) {
        finishWriting(withError: .vtDecoderError)
    }

    // MARK: - Private Methods

    private func startProcessing() {
        // We need first to get sps/pps packets and initialize decoder in assetWriterInput
        while let nalu = naluParser.parseNext() {
            guard !isFinished else { return }

            // we need to save sps/pps and setup writerInput with these settings
            if [H264NALUType.sps, .pps, .sei].contains(nalu.type) {
                if nalu.type == .sps {
                    spsBytes = nalu.bytes
                } else if nalu.type == .pps {
                    ppsBytes = nalu.bytes
                } else {
                    continue
                }

                if !spsBytes.isEmpty, !ppsBytes.isEmpty {
                    setup(spsBytes: spsBytes, ppsBytes: ppsBytes)
                    return
                }
            }
        }
        finishWriting(withError: .wrongStream)
    }

    private func setup(
        spsBytes: [UInt8],
        ppsBytes: [UInt8]
    ) {
        guard
            self.assetWriterInput == nil,
            let formatDescription = getFormatDescription(
                spsBytes: spsBytes,
                ppsBytes: ppsBytes
            )
        else {
            finishWriting(withError: .unableToGetFormatDescription)
            return
        }

        // initialize writer
        assetWriter.shouldOptimizeForNetworkUse = true

        // initialize writerInput
        let assetWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: inputFileConfig.imageSize.width,
                AVVideoHeightKey: inputFileConfig.imageSize.height
            ]
        )
        self.assetWriterInput = assetWriterInput
        assetWriterInput.expectsMediaDataInRealTime = true // with this property work much faster
        if assetWriter.canAdd(assetWriterInput) {
            assetWriter.add(assetWriterInput)
        } else {
            finishWriting(withError: .unableToStartWriting)
            return
        }

        // initialize writerInputAdaptor
        assetWriterInputAdaptor = .init(assetWriterInput: assetWriterInput)

        // start writing
        if assetWriter.startWriting() {
            assetWriter.startSession(atSourceTime: .zero)
        } else {
            finishWriting(withError: .unableToStartWriting)
            return
        }

        // setup vtDecoder
        do {
            try vtDecoder.setup(formatDescription: formatDescription)
        } catch {
            finishWriting(withError: .vtDecoderError)
            return
        }

        // react when mediaDataReady
        assetWriterInput.requestMediaDataWhenReady(on: workingQueue) { [weak self] in
            guard
                let self,
                let assetWriterInput = self.assetWriterInput,
                let assetWriterInputAdaptor = self.assetWriterInputAdaptor
            else { return }

            // write queued pixelBuffer when ready
            while
                let first = self.cvPixelBuffersQueue.first,
                assetWriterInput.isReadyForMoreMediaData {
                let time = self.getTime(forIndex: self.currentIndex)
                if !assetWriterInputAdaptor.append(
                    first.buffer,
                    withPresentationTime: time
                ) {
                    self.finishWriting(withError: .avFoundationError(self.assetWriter.error))
                    return
                }
                self.currentIndex += 1

                CVPixelBufferUnlockBaseAddress(first.buffer, .readOnly)

                self.cvPixelBuffersQueue.remove(at: 0)
            }

            if let next = self.naluParser.parseNext() {
                self.numberOfActiveRequests += 1
                self.vtDecoder.decode(nalu: next)
                return
            } else {
                self.naluParserFinished = true
            }

            if
                self.naluParserFinished,
                self.numberOfActiveRequests == 0,
                self.cvPixelBuffersQueue.isEmpty {
                self.finishWriting()
                return
            }
        }
    }

    private func finishWriting() {
        guard cvPixelBuffersQueue.isEmpty else {
            assertionFailure("cvPixelBuffersQueue must be empty when finishing without error")
            return
        }

        if assetWriter.status == .unknown {
            finishWriting(withError: .unknownWriterState)
            return
        }
        isFinished = true
        assetWriterInput?.markAsFinished()
        vtDecoder.invalidate()

        let endTime = getTime(forIndex: currentIndex)
        assetWriter.endSession(atSourceTime: endTime)
        assetWriter.finishWriting { [weak self] in
            guard let self else { return }
            self.completionSubject.send(self.assetWriter.outputURL)
            self.completionSubject.send(completion: .finished)
        }
    }

    private func finishWriting(withError error: H264StreamToFileConverterError) {
        vtDecoder.invalidate()

        unlockBuffersIfNeeded()
        isFinished = true

        if assetWriterInput?.isReadyForMoreMediaData == true {
            assetWriterInput?.markAsFinished()
        }

        completionSubject.send(completion: .failure(error))
    }

    private func getTime(forIndex index: Int) -> CMTime {
        let time = CMTimeMake(
            value: Int64(index),
            timescale: Int32(inputFileConfig.frameRate)
        )
        return time
    }

    private func getFormatDescription(
        spsBytes: [UInt8],
        ppsBytes: [UInt8]
    ) -> CMFormatDescription? {
        guard
            let avccCfData = AVCCExtractor.avccExtradataCreate(
                spsBytes: spsBytes,
                ppsBytes: ppsBytes
            )
        else { return nil }
        let cfDict = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [
                "avcC" as String: avccCfData
            ] as CFDictionary
        ] as CFDictionary

        var videoFormatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: Int32(inputFileConfig.imageSize.width),
            height: Int32(inputFileConfig.imageSize.height),
            extensions: cfDict,
            formatDescriptionOut: &videoFormatDescription
        )

        return videoFormatDescription
    }

    private func unlockBuffersIfNeeded() {
        // need to avoid multiple unlocking
        cvPixelBuffersQueue
            .enumerated()
            .filter { $0.element.isLocked }
            .forEach {
                CVPixelBufferUnlockBaseAddress($0.element.buffer, .readOnly)
                cvPixelBuffersQueue[$0.offset].isLocked = false
            }
    }

}
