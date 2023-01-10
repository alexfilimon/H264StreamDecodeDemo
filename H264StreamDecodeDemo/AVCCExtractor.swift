import CoreFoundation

enum AVCCExtractor {

    // MARK: - Static Methods

    static func avccExtradataCreate(
        spsBytes: [UInt8],
        ppsBytes: [UInt8]
    ) -> CFData? {
        guard
            spsBytes.count > 3,
            !ppsBytes.isEmpty
        else {
            return nil
        }

        // sizes in bytes
        let metadataSize = 6
        let sizeOfSpsBytesSize = 2
        let sizeOfPpsBytesSize = 2
        let numberOfPpsSize = 1
        let extraDataSize = metadataSize + sizeOfSpsBytesSize + spsBytes
            .count + numberOfPpsSize + sizeOfPpsBytesSize + ppsBytes.count

        // bytes for avcc
        var extraBytes: [UInt8] = .init(repeating: 0, count: extraDataSize)
        extraBytes[0] = 1 // version
        extraBytes[1] = spsBytes[1] // profile
        extraBytes[2] = spsBytes[2] // profile compat
        extraBytes[3] = spsBytes[3] // level
        extraBytes[4] = 0xFF // 6 bits reserved (111111) + 2 bits nal size length - 1 (11)
        extraBytes[5] = 0xE1 // 3 bits reserved (111) + 5 bits number of sps (00001)
        write(
            uInt16: UInt16(spsBytes.count),
            to: &extraBytes,
            startingIndex: 6
        ) // size of sps
        copyAllElements(
            from: spsBytes,
            to: &extraBytes,
            startingIndex: 8
        )
        extraBytes[8 + spsBytes.count] = 1 // number of pps
        write(
            uInt16: UInt16(ppsBytes.count),
            to: &extraBytes,
            startingIndex: 8 + spsBytes.count + 1
        ) // size of pps
        copyAllElements(
            from: ppsBytes,
            to: &extraBytes,
            startingIndex: 8 + spsBytes.count + 3
        )
        return CFDataCreate(
            kCFAllocatorDefault,
            extraBytes,
            extraBytes.count
        )
    }

    // MARK: - Private Static Methods

    private static func copyAllElements<T>(
        from fromArray: [T],
        to toArray: inout [T],
        startingIndex: Int
    ) {
        for (index, item) in fromArray.enumerated() {
            toArray[startingIndex + index] = item
        }
    }

    private static func write(
        uInt16: UInt16,
        to array: inout [UInt8],
        startingIndex: Int
    ) {
        array[startingIndex] = UInt8(truncatingIfNeeded: uInt16 >> 8)
        array[startingIndex + 1] = UInt8(truncatingIfNeeded: uInt16)
    }

}
