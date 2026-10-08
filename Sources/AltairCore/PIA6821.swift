/// Motorola MC6821 PIA(ペリフェラル・インターフェース・アダプタ)の、68-UIO のディスク接続に必要な範囲。
///
/// レジスタ(RS1, RS0): 0 = ポート A データ/DDR、1 = 制御 A、2 = ポート B データ/DDR、3 = 制御 B。
/// 制御レジスタ bit 2 が 1 ならデータレジスタ、0 なら方向レジスタ(DDR)を選ぶ。
///
/// ハンドシェイク出力 CA2 / CB2 は、制御レジスタ bit 5 = 1、bit 4 = 0 のとき(ハンドシェイクまたはパルス出力)、
/// - CA2: ポート A のデータレジスタを読んだとき
/// - CB2: ポート B のデータレジスタに書いたとき
/// にストローブする(`onCA2Strobe` / `onCB2Strobe`)。bit 5 = 1、bit 4 = 1 のときは手動で出力を固定する(ストローブしない)。
///
/// 割り込みフラグ(IRQ)は扱わない。
public final class PIA6821 {
    public private(set) var cra: UInt8 = 0
    public private(set) var crb: UInt8 = 0
    public private(set) var ddra: UInt8 = 0
    public private(set) var ddrb: UInt8 = 0
    public private(set) var ora: UInt8 = 0
    public private(set) var orb: UInt8 = 0

    /// 外部からポート A / B のピンに加わる値(入力に設定したビットで読まれる)
    public var inputA: () -> UInt8 = { 0xFF }
    public var inputB: () -> UInt8 = { 0xFF }
    public var onCA2Strobe: (() -> Void)?
    public var onCB2Strobe: (() -> Void)?

    public init() {}

    /// 出力に設定したビットでピンへ出ている値
    public var outputA: UInt8 { ora & ddra }
    public var outputB: UInt8 { orb & ddrb }

    public func reset() {
        cra = 0; crb = 0; ddra = 0; ddrb = 0; ora = 0; orb = 0
    }

    private static func strobes(_ control: UInt8) -> Bool { control & 0x30 == 0x20 }

    public func read(_ reg: Int) -> UInt8 {
        switch reg & 3 {
        case 0:
            if cra & 0x04 == 0 { return ddra }
            let v = (ora & ddra) | (inputA() & ~ddra)
            if Self.strobes(cra) { onCA2Strobe?() }
            return v
        case 1: return cra
        case 2:
            if crb & 0x04 == 0 { return ddrb }
            return (orb & ddrb) | (inputB() & ~ddrb)
        default: return crb
        }
    }

    public func write(_ reg: Int, _ value: UInt8) {
        switch reg & 3 {
        case 0:
            if cra & 0x04 == 0 { ddra = value } else { ora = value }
        case 1: cra = value & 0x3F
        case 2:
            if crb & 0x04 == 0 {
                ddrb = value
            } else {
                orb = value
                if Self.strobes(crb) { onCB2Strobe?() }
            }
        default: crb = value & 0x3F
        }
    }
}
