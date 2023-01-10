import Foundation

/// Entity for parsing h264 stream to NALU packets
public protocol H264NALUParser {
    func parseNext() -> H264NALU?
}

enum H264NALUParserInputStreamError: Error {
    case unableToInitializeInputStream
}

/// Implementation `NALUParser` with `InputStream`
public class H264NALUParserInputStream: H264NALUParser {

    // MARK: - Constants

    private enum Constants {
        static let bufferCap = 512 * 1024
    }

    // MARK: - Properties

    var streamBuffer: [UInt8] = []
    let fileStream: InputStream

    // MARK: - Initialization

    public init(fileURL: URL) throws {
        guard let inputStream = InputStream(url: fileURL) else {
            throw H264NALUParserInputStreamError.unableToInitializeInputStream
        }
        fileStream = inputStream
        fileStream.open()
    }

    deinit {
        fileStream.close()
    }

    // MARK: - Methods

    public func parseNext() -> H264NALU? {
        if streamBuffer.isEmpty && readStreamData() == 0 {
            return nil
        }

        // make sure start with start code
        if streamBuffer.count <= H264NALU.Constants
            .startCodeLen || Array(streamBuffer[0..<H264NALU.Constants.startCodeLen]) != H264NALU.Constants.startCode {
            assert(streamBuffer.isEmpty)
            return nil
        }

        // find second start code, so startIndex = 4
        var startIndex = H264NALU.Constants.startCodeLen

        while true {
            while (startIndex + H264NALU.Constants.startCodeLen) < streamBuffer.count {
                let startCodeArray = Array(streamBuffer[startIndex..<startIndex + H264NALU.Constants.startCodeLen])
                if startCodeArray == H264NALU.Constants.startCode {
                    return createPacker(startIndex: startIndex)
                }
                startIndex += 1
            }

            // Not found next start code, read more data.
            // If there is no more data - return last packet
            if readStreamData() == 0 {
                if startIndex > H264NALU.Constants.startCodeLen {
                    return createPacker(startIndex: startIndex + H264NALU.Constants.startCodeLen)
                }
                return nil
            }
        }
    }

    // MARK: - Private Methods

    /// Method to read next buffer of stream
    private func readStreamData() -> Int {
        guard fileStream.hasBytesAvailable else {
            return 0
        }
        var tempArray = [UInt8](repeating: 0, count: Constants.bufferCap)
        let bytes = fileStream.read(&tempArray, maxLength: Constants.bufferCap)

        if bytes > 0 {
            streamBuffer.append(contentsOf: Array(tempArray[0..<bytes]))
        }

        return bytes
    }

    private func createPacker(startIndex: Int) -> H264NALU {
        let packet = Array(streamBuffer[H264NALU.Constants.startCodeLen..<startIndex])
        streamBuffer.removeSubrange(0..<startIndex)
        return .init(bytes: packet)
    }

}

