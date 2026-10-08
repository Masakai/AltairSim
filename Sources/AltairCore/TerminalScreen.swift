/// 80 桁 × 24 行の文字端末。制御文字と、エスケープシーケンスの一部を解釈する。
///
/// - 制御文字: CR、LF、BS(カーソルを 1 つ戻す。文字は消さない)、TAB(8 桁ごと)。BEL、DEL などは無視する
/// - ANSI(VT100 系): ESC [ H / f(位置指定)、A B C D(移動)、J(画面消去)、K(行消去)、L M(行挿入・削除)、m(属性は無視)
/// - ADM-3A: ESC = 行 桁(位置指定、行・桁は 20h からの値)、1Eh(ホーム)、1Ah(画面消去してホーム)
public struct TerminalScreen: Equatable {
    public static let columns = 80
    public static let rows = 24

    public private(set) var cells: [[UInt8]]
    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0

    private enum State: Equatable {
        case normal
        case escape
        case csi(String)
        case admRow
        case admCol(Int)
    }
    private var state = State.normal

    public init() {
        cells = Array(repeating: Array(repeating: 0x20, count: Self.columns), count: Self.rows)
    }

    public func rowString(_ r: Int) -> String {
        String(decoding: cells[r], as: UTF8.self)
    }

    /// カーソルの表示位置(右端で折り返す直前は最終桁に表示する)
    public var displayCursor: (row: Int, col: Int) {
        (cursorRow, min(cursorCol, Self.columns - 1))
    }

    // MARK: 入力

    public mutating func put(_ byte: UInt8) {
        let b = byte & 0x7F
        switch state {
        case .normal:
            putNormal(b)
        case .escape:
            switch b {
            case 0x5B: state = .csi("")     // ESC [
            case 0x3D: state = .admRow      // ESC =
            default: state = .normal        // 未対応のシーケンスは捨てる
            }
        case .csi(let params):
            if (0x30...0x3F).contains(b) {           // 数字 ; ? など
                state = .csi(params + String(UnicodeScalar(b)))
            } else if (0x40...0x7E).contains(b) {    // 終端文字
                state = .normal
                csi(params, final: b)
            } else {
                state = .normal
            }
        case .admRow:
            state = .admCol(Int(b) - 0x20)
        case .admCol(let row):
            state = .normal
            moveTo(row: row, col: Int(b) - 0x20)
        }
    }

    private mutating func putNormal(_ b: UInt8) {
        switch b {
        case 0x1B: state = .escape
        case 0x0D: cursorCol = 0
        case 0x0A: lineFeed()
        case 0x08: if cursorCol > 0 { cursorCol -= 1 }
        case 0x09: cursorCol = min((cursorCol / 8 + 1) * 8, Self.columns - 1)
        case 0x1E: cursorRow = 0; cursorCol = 0
        case 0x1A: clearAll(); cursorRow = 0; cursorCol = 0
        case 0x20...0x7E:
            if cursorCol >= Self.columns {  // 右端を超えたら折り返す
                cursorCol = 0
                lineFeed()
            }
            cells[cursorRow][cursorCol] = b
            cursorCol += 1
        default: break  // BEL、DEL、その他の制御文字は無視
        }
    }

    // MARK: 画面操作

    private mutating func lineFeed() {
        if cursorRow == Self.rows - 1 {
            cells.removeFirst()
            cells.append(Array(repeating: 0x20, count: Self.columns))
        } else {
            cursorRow += 1
        }
    }

    private mutating func moveTo(row: Int, col: Int) {
        cursorRow = min(max(row, 0), Self.rows - 1)
        cursorCol = min(max(col, 0), Self.columns - 1)
    }

    private mutating func clearAll() {
        for r in 0..<Self.rows { cells[r] = Array(repeating: 0x20, count: Self.columns) }
    }

    private mutating func csi(_ params: String, final: UInt8) {
        let nums = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        func n(_ i: Int, default d: Int) -> Int {
            guard i < nums.count, let v = nums[i] else { return d }
            return v
        }
        switch final {
        case 0x48, 0x66:  // H, f: 行;桁(1 始まり)
            moveTo(row: n(0, default: 1) - 1, col: n(1, default: 1) - 1)
        case 0x41: moveTo(row: cursorRow - max(n(0, default: 1), 1), col: cursorCol)  // A 上
        case 0x42: moveTo(row: cursorRow + max(n(0, default: 1), 1), col: cursorCol)  // B 下
        case 0x43: moveTo(row: cursorRow, col: cursorCol + max(n(0, default: 1), 1))  // C 右
        case 0x44: moveTo(row: cursorRow, col: cursorCol - max(n(0, default: 1), 1))  // D 左
        case 0x4A:  // J: 0 = カーソル以降、1 = 先頭からカーソルまで、2 = 全体
            let col = min(cursorCol, Self.columns - 1)
            switch n(0, default: 0) {
            case 0:
                for c in col..<Self.columns { cells[cursorRow][c] = 0x20 }
                if cursorRow + 1 < Self.rows { for r in (cursorRow + 1)..<Self.rows { cells[r] = Array(repeating: 0x20, count: Self.columns) } }
            case 1:
                for r in 0..<cursorRow { cells[r] = Array(repeating: 0x20, count: Self.columns) }
                for c in 0...col { cells[cursorRow][c] = 0x20 }
            default:
                clearAll()
            }
        case 0x4B:  // K: 0 = カーソル以降、1 = 行頭からカーソルまで、2 = 行全体
            let col = min(cursorCol, Self.columns - 1)
            switch n(0, default: 0) {
            case 0: for c in col..<Self.columns { cells[cursorRow][c] = 0x20 }
            case 1: for c in 0...col { cells[cursorRow][c] = 0x20 }
            default: cells[cursorRow] = Array(repeating: 0x20, count: Self.columns)
            }
        case 0x4C:  // L: 行挿入
            for _ in 0..<max(n(0, default: 1), 1) {
                cells.removeLast()
                cells.insert(Array(repeating: 0x20, count: Self.columns), at: cursorRow)
            }
        case 0x4D:  // M: 行削除
            for _ in 0..<max(n(0, default: 1), 1) {
                cells.remove(at: cursorRow)
                cells.append(Array(repeating: 0x20, count: Self.columns))
            }
        default:
            break  // m(文字属性)など、未対応のものは無視
        }
    }
}
