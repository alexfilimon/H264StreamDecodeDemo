import Foundation

/// Type
public enum H264NALUType: UInt8, CustomStringConvertible {
    case undefined = 0
    case codedSlice = 1
    case dataPartitionA = 2
    case dataPartitionB = 3
    case dataPartitionC = 4
    case idr = 5 // (Instantaneous Decoding Refresh) Picture
    case sei = 6 // (Supplemental Enhancement Information)
    case sps = 7 // (Sequence Parameter Set)
    case pps = 8 // (Picture Parameter Set)
    case accessUnitDelimiter = 9
    case endOfSequence = 10
    case endOfStream = 11
    case filterData = 12
    // 13-23 [extended]
    // 24-31 [unspecified]

    // MARK: - Properties

    public var description: String {
        switch self {
        case .codedSlice:
            return "CodedSlice"
        case .dataPartitionA:
            return "DataPartitionA"
        case .dataPartitionB:
            return "DataPartitionB"
        case .dataPartitionC:
            return "DataPartitionC"
        case .idr:
            return "IDR"
        case .sei:
            return "SEI"
        case .sps:
            return "SPS"
        case .pps:
            return "PPS"
        case .accessUnitDelimiter:
            return "AccessUnitDelimiter"
        case .endOfSequence:
            return "EndOfSequence"
        case .endOfStream:
            return "EndOfStream"
        case .filterData:
            return "FilterData"
        default:
            return "Undefined"
        }
    }
}

/// represent NALU packet in h264 stream
public struct H264NALU: Hashable {

    // MARK: - Constants

    enum Constants {
        static let startCode: [UInt8] = [0, 0, 0, 1]
        static var startCodeLen: Int {
            startCode.count
        }
    }

    // MARK: - Properties

    public let type: H264NALUType
    public let bytes: [UInt8]

    // MARK: - Initialization

    init(bytes: [UInt8]) {
        self.bytes = bytes

        var type: H264NALUType?
        if let first = bytes.first {
            /// type store in first byte (first 3 bits - represent additional metadata,
            /// while next 5 bit - concrete NALU type)
            if ((first >> 7) & 0x01) == 0 {
                /// first byte multiplies to 00011111 and we give real type of NALU
                type = H264NALUType(rawValue: first & 0x1F)
            }
        }
        self.type = type ?? .undefined
    }
}
