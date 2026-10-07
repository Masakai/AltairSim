public enum HexLoaderError: Error, CustomStringConvertible {
    case invalidLine(Int)
    case checksum(Int)

    public var description: String {
        switch self {
        case .invalidLine(let n): return "\(n) 行目の形式が不正です"
        case .checksum(let n): return "\(n) 行目のチェックサムが一致しません"
        }
    }
}

/// Intel HEX(データレコード 00 と EOF レコード 01 のみ対応)
public enum HexLoader {
    public static func parse(_ text: String) throws -> [(address: UInt16, bytes: [UInt8])] {
        var result: [(UInt16, [UInt8])] = []
        for (idx, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let lineNo = idx + 1
            let line = raw.filter { !$0.isWhitespace }
            if line.isEmpty { continue }
            guard line.hasPrefix(":") else { throw HexLoaderError.invalidLine(lineNo) }
            let hex = Array(line.dropFirst())
            guard hex.count >= 10, hex.count % 2 == 0 else { throw HexLoaderError.invalidLine(lineNo) }
            var data: [UInt8] = []
            var i = 0
            while i < hex.count {
                guard let v = UInt8(String(hex[i..<i + 2]), radix: 16) else {
                    throw HexLoaderError.invalidLine(lineNo)
                }
                data.append(v)
                i += 2
            }
            let length = Int(data[0])
            guard data.count == length + 5 else { throw HexLoaderError.invalidLine(lineNo) }
            let sum = data.reduce(0) { $0 &+ Int($1) } & 0xFF
            guard sum == 0 else { throw HexLoaderError.checksum(lineNo) }
            let address = UInt16(data[1]) << 8 | UInt16(data[2])
            switch data[3] {
            case 0x00: result.append((address, Array(data[4..<4 + length])))
            case 0x01: return result
            default: throw HexLoaderError.invalidLine(lineNo)
            }
        }
        return result
    }
}
