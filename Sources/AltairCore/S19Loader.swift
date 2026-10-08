public enum S19LoaderError: Error, CustomStringConvertible {
    case invalidLine(Int)
    case checksum(Int)

    public var description: String {
        switch self {
        case .invalidLine(let n): return "\(n) 行目の形式が不正です"
        case .checksum(let n): return "\(n) 行目のチェックサムが一致しません"
        }
    }
}

/// Motorola S レコード(S1 のデータ、S9 の終了。S0 のヘッダは読み飛ばす)
public enum S19Loader {
    public static func parse(_ text: String) throws -> [(address: UInt16, bytes: [UInt8])] {
        var result: [(UInt16, [UInt8])] = []
        for (idx, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let lineNo = idx + 1
            let line = raw.filter { !$0.isWhitespace }
            if line.isEmpty { continue }
            guard line.hasPrefix("S"), line.count >= 4 else { throw S19LoaderError.invalidLine(lineNo) }
            let kind = line[line.index(after: line.startIndex)]
            let hex = Array(line.dropFirst(2))
            guard hex.count % 2 == 0 else { throw S19LoaderError.invalidLine(lineNo) }
            var data: [UInt8] = []
            var i = 0
            while i < hex.count {
                guard let v = UInt8(String(hex[i..<i + 2]), radix: 16) else { throw S19LoaderError.invalidLine(lineNo) }
                data.append(v)
                i += 2
            }
            guard data.count >= 3, Int(data[0]) == data.count - 1 else { throw S19LoaderError.invalidLine(lineNo) }
            let sum = data.dropLast().reduce(0) { $0 &+ Int($1) } & 0xFF
            guard (~sum & 0xFF) == Int(data.last!) else { throw S19LoaderError.checksum(lineNo) }
            switch kind {
            case "1":
                let address = UInt16(data[1]) << 8 | UInt16(data[2])
                result.append((address, Array(data[3..<data.count - 1])))
            case "9":
                return result
            default:
                continue  // S0 ヘッダなど
            }
        }
        return result
    }
}
