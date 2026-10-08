/// Motorola MC6800 エミュレータ(Altair 680b 用)。命令単位で実行し、消費クロック数を返す。
///
/// - 入出力はメモリ空間に割り当てる(I/O 命令はない)。`Bus` の input/output は使わない
/// - スタックは PC を下位バイト → 上位バイトの順に積み、SP を書き込みのたびに 1 減らす
/// - ベクタ(上位バイトが若い番地): IRQ = FFF8、SWI = FFFA、NMI = FFFC、RESET = FFFE
/// - 未定義のオペコードは 2 クロックの NOP として扱い、`illegalCount` に数える
public final class CPU6800 {
    public var a: UInt8 = 0
    public var b: UInt8 = 0
    public var x: UInt16 = 0
    public var sp: UInt16 = 0
    public var pc: UInt16 = 0
    /// 条件コード: ハーフキャリー、割り込みマスク、負、ゼロ、オーバーフロー、キャリー
    public var h = false, i = true, n = false, z = false, v = false, c = false

    /// WAI で割り込みを待っている
    public private(set) var waiting = false
    /// NMI 要求(エッジ。受け付けたら自動で落ちる)
    public var nmiPending = false
    /// IRQ 入力(レベル。I フラグが 0 のときに受け付ける)
    public var irq = false

    public private(set) var illegalCount = 0
    public private(set) var lastIllegal: UInt8?

    private unowned let bus: Bus

    public init(bus: Bus) {
        self.bus = bus
    }

    /// 条件コードレジスタ(11HINZVC)
    public var cc: UInt8 {
        get {
            0xC0 | (h ? 0x20 : 0) | (i ? 0x10 : 0) | (n ? 0x08 : 0)
                | (z ? 0x04 : 0) | (v ? 0x02 : 0) | (c ? 0x01 : 0)
        }
        set {
            h = newValue & 0x20 != 0
            i = newValue & 0x10 != 0
            n = newValue & 0x08 != 0
            z = newValue & 0x04 != 0
            v = newValue & 0x02 != 0
            c = newValue & 0x01 != 0
        }
    }

    /// RESET: I = 1、PC をリセットベクタ(FFFE)から読む。レジスタ A、B、X、SP は変わらない。
    public func reset() {
        i = true
        waiting = false
        nmiPending = false
        pc = read16(0xFFFE)
    }

    // MARK: バスアクセス

    private func fetch() -> UInt8 {
        let value = bus.read(pc)
        pc &+= 1
        return value
    }

    private func fetch16() -> UInt16 {
        let hi = UInt16(fetch())
        let lo = UInt16(fetch())
        return hi << 8 | lo
    }

    private func read16(_ addr: UInt16) -> UInt16 {
        UInt16(bus.read(addr)) << 8 | UInt16(bus.read(addr &+ 1))
    }

    private func write16(_ addr: UInt16, _ value: UInt16) {
        bus.write(addr, UInt8(value >> 8))
        bus.write(addr &+ 1, UInt8(value & 0xFF))
    }

    private func push8(_ value: UInt8) {
        bus.writeStack(sp, value)
        sp &-= 1
    }

    private func pull8() -> UInt8 {
        sp &+= 1
        return bus.readStack(sp)
    }

    private func pushPC() {
        push8(UInt8(pc & 0xFF))
        push8(UInt8(pc >> 8))
    }

    private func pullPC() {
        let hi = UInt16(pull8())
        let lo = UInt16(pull8())
        pc = hi << 8 | lo
    }

    private func pushAll() {
        pushPC()
        push8(UInt8(x & 0xFF))
        push8(UInt8(x >> 8))
        push8(a)
        push8(b)
        push8(cc)
    }

    // MARK: フラグと演算

    private func setNZ(_ r: UInt8) {
        n = r & 0x80 != 0
        z = r == 0
    }

    private func setNZ16(_ r: UInt16) {
        n = r & 0x8000 != 0
        z = r == 0
    }

    private func add(_ p: UInt8, _ q: UInt8, carry: Bool) -> UInt8 {
        let ci = carry ? 1 : 0
        let sum = Int(p) + Int(q) + ci
        let r = UInt8(sum & 0xFF)
        h = (Int(p & 0x0F) + Int(q & 0x0F) + ci) > 0x0F
        c = sum > 0xFF
        v = ((p ^ r) & (q ^ r) & 0x80) != 0
        setNZ(r)
        return r
    }

    private func sub(_ p: UInt8, _ q: UInt8, carry: Bool) -> UInt8 {
        let diff = Int(p) - Int(q) - (carry ? 1 : 0)
        let r = UInt8(truncatingIfNeeded: diff)
        c = diff < 0
        v = ((p ^ q) & (p ^ r) & 0x80) != 0
        setNZ(r)
        return r
    }

    private func daa() {
        let hi = a >> 4, lo = a & 0x0F
        var correction: UInt8 = 0
        var carry = c
        if lo > 9 || h { correction |= 0x06 }
        if hi > 9 || c || (hi > 8 && lo > 9) {
            correction |= 0x60
            carry = true
        }
        a = a &+ correction
        setNZ(a)
        c = carry
    }

    /// 単項演算。TST は結果を書き戻さないので nil を返す。
    private func unary(_ kind: UInt8, _ m: UInt8) -> UInt8? {
        var r: UInt8
        switch kind {
        case 0x0:  // NEG
            r = 0 &- m
            setNZ(r)
            v = m == 0x80
            c = m != 0
        case 0x3:  // COM
            r = ~m
            setNZ(r)
            v = false
            c = true
        case 0x4:  // LSR
            c = m & 1 != 0
            r = m >> 1
            n = false
            z = r == 0
            v = n != c
        case 0x6:  // ROR
            let old = c
            c = m & 1 != 0
            r = m >> 1 | (old ? 0x80 : 0)
            setNZ(r)
            v = n != c
        case 0x7:  // ASR
            c = m & 1 != 0
            r = m >> 1 | (m & 0x80)
            setNZ(r)
            v = n != c
        case 0x8:  // ASL
            c = m & 0x80 != 0
            r = m << 1
            setNZ(r)
            v = n != c
        case 0x9:  // ROL
            let old = c
            c = m & 0x80 != 0
            r = m << 1 | (old ? 1 : 0)
            setNZ(r)
            v = n != c
        case 0xA:  // DEC
            r = m &- 1
            setNZ(r)
            v = m == 0x80
        case 0xC:  // INC
            r = m &+ 1
            setNZ(r)
            v = m == 0x7F
        case 0xD:  // TST
            setNZ(m)
            v = false
            c = false
            return nil
        default:  // 0xF CLR
            r = 0
            n = false
            z = true
            v = false
            c = false
        }
        return r
    }

    private static let validUnary: Set<UInt8> = [0x0, 0x3, 0x4, 0x6, 0x7, 0x8, 0x9, 0xA, 0xC, 0xD, 0xF]

    private func condition(_ code: UInt8) -> Bool {
        switch code {
        case 0x0: return true          // BRA
        case 0x1: return false         // BRN(6800 では未定義)
        case 0x2: return !(c || z)     // BHI
        case 0x3: return c || z        // BLS
        case 0x4: return !c            // BCC
        case 0x5: return c             // BCS
        case 0x6: return !z            // BNE
        case 0x7: return z             // BEQ
        case 0x8: return !v            // BVC
        case 0x9: return v             // BVS
        case 0xA: return !n            // BPL
        case 0xB: return n             // BMI
        case 0xC: return n == v        // BGE
        case 0xD: return n != v        // BLT
        case 0xE: return !z && n == v  // BGT
        default: return z || n != v    // BLE
        }
    }

    // MARK: 割り込み

    private func interrupt(vector: UInt16) -> Int {
        if !waiting { pushAll() }
        waiting = false
        i = true
        pc = read16(vector)
        return 12
    }

    // MARK: 実行

    /// 1 命令を実行して消費クロック数を返す。WAI 中は割り込みが来るまで 4 を返し続ける。
    @discardableResult
    public func step() -> Int {
        if nmiPending {
            nmiPending = false
            return interrupt(vector: 0xFFFC)
        }
        if irq && !i {
            return interrupt(vector: 0xFFF8)
        }
        if waiting { return 4 }

        let op = bus.fetchOpcode(pc)
        pc &+= 1
        switch op {
        case 0x00...0x3F: return inherentOrBranch(op)
        case 0x40...0x5F: return accumulatorUnary(op)
        case 0x60...0x7F: return memoryUnary(op)
        default: return accumulatorOrIndex(op)
        }
    }

    private func illegal(_ op: UInt8) -> Int {
        illegalCount += 1
        lastIllegal = op
        return 2
    }

    private func inherentOrBranch(_ op: UInt8) -> Int {
        if op >= 0x20 && op <= 0x2F {
            let offset = Int8(bitPattern: fetch())
            if op == 0x21 {  // BRN は 6801 の命令。6800 では未定義(実機では分岐しない 2 バイト命令として動く)
                illegalCount += 1
                lastIllegal = op
                return 4
            }
            if condition(op & 0x0F) {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
            }
            return 4
        }
        switch op {
        case 0x01: return 2  // NOP
        case 0x06: cc = a; return 2                       // TAP
        case 0x07: a = cc; return 2                       // TPA
        case 0x08: x &+= 1; z = x == 0; return 4          // INX
        case 0x09: x &-= 1; z = x == 0; return 4          // DEX
        case 0x0A: v = false; return 2                    // CLV
        case 0x0B: v = true; return 2                     // SEV
        case 0x0C: c = false; return 2                    // CLC
        case 0x0D: c = true; return 2                     // SEC
        case 0x0E: i = false; return 2                    // CLI
        case 0x0F: i = true; return 2                     // SEI
        case 0x10: a = sub(a, b, carry: false); return 2  // SBA
        case 0x11: _ = sub(a, b, carry: false); return 2  // CBA
        case 0x16: b = a; setNZ(b); v = false; return 2   // TAB
        case 0x17: a = b; setNZ(a); v = false; return 2   // TBA
        case 0x19: daa(); return 2                        // DAA
        case 0x1B: a = add(a, b, carry: false); return 2  // ABA
        case 0x30: x = sp &+ 1; return 4                  // TSX
        case 0x31: sp &+= 1; return 4                     // INS
        case 0x32: a = pull8(); return 4                  // PULA
        case 0x33: b = pull8(); return 4                  // PULB
        case 0x34: sp &-= 1; return 4                     // DES
        case 0x35: sp = x &- 1; return 4                  // TXS
        case 0x36: push8(a); return 4                     // PSHA
        case 0x37: push8(b); return 4                     // PSHB
        case 0x39: pullPC(); return 5                     // RTS
        case 0x3B:                                        // RTI
            cc = pull8()
            b = pull8()
            a = pull8()
            let xh = UInt16(pull8())
            let xl = UInt16(pull8())
            x = xh << 8 | xl
            pullPC()
            return 10
        case 0x3E:                                        // WAI
            pushAll()
            waiting = true
            return 9
        case 0x3F:                                        // SWI
            pushAll()
            i = true
            pc = read16(0xFFFA)
            return 12
        default: return illegal(op)
        }
    }

    private func accumulatorUnary(_ op: UInt8) -> Int {
        let kind = op & 0x0F
        guard Self.validUnary.contains(kind) else { return illegal(op) }
        if op & 0x10 == 0 {
            if let r = unary(kind, a) { a = r }
        } else {
            if let r = unary(kind, b) { b = r }
        }
        return 2
    }

    private func memoryUnary(_ op: UInt8) -> Int {
        let indexed = op < 0x70
        let kind = op & 0x0F
        if kind == 0xE {  // JMP
            pc = indexed ? x &+ UInt16(fetch()) : fetch16()
            return indexed ? 4 : 3
        }
        guard Self.validUnary.contains(kind) else { return illegal(op) }
        let addr = indexed ? x &+ UInt16(fetch()) : fetch16()
        if let r = unary(kind, bus.read(addr)) { bus.write(addr, r) }
        return indexed ? 7 : 6
    }

    /// 0x80〜0xFF: A/B アキュムレータの演算、CPX、LDS、LDX、STS、STX、BSR、JSR
    private func accumulatorOrIndex(_ op: UInt8) -> Int {
        let isA = op < 0xC0
        let mode = Int((op >> 4) & 3)  // 0 即値、1 ダイレクト、2 インデックス、3 拡張
        let low = op & 0x0F
        let accCycles = [2, 3, 5, 4]
        let storeCycles = [0, 4, 6, 5]
        let wordCycles = [3, 4, 6, 5]
        let wordStoreCycles = [0, 5, 7, 6]

        func address() -> UInt16 {
            switch mode {
            case 0:
                let a = pc
                pc &+= 1
                return a
            case 1: return UInt16(fetch())
            case 2: return x &+ UInt16(fetch())
            default: return fetch16()
            }
        }
        func word() -> UInt16 {  // 16 ビットのオペランド(即値のときは直後の 2 バイト)
            if mode == 0 { return fetch16() }
            return read16(address())
        }
        func reg() -> UInt8 { isA ? a : b }
        func setReg(_ value: UInt8) { if isA { a = value } else { b = value } }

        switch low {
        case 0x0:  // SUB
            setReg(sub(reg(), bus.read(address()), carry: false)); return accCycles[mode]
        case 0x1:  // CMP
            _ = sub(reg(), bus.read(address()), carry: false); return accCycles[mode]
        case 0x2:  // SBC
            setReg(sub(reg(), bus.read(address()), carry: c)); return accCycles[mode]
        case 0x3:  // 6800 にはない(6801 の SUBD / ADDD など)
            return illegal(op)
        case 0x4:  // AND
            let r = reg() & bus.read(address()); setReg(r); setNZ(r); v = false; return accCycles[mode]
        case 0x5:  // BIT
            setNZ(reg() & bus.read(address())); v = false; return accCycles[mode]
        case 0x6:  // LDA
            let r = bus.read(address()); setReg(r); setNZ(r); v = false; return accCycles[mode]
        case 0x7:  // STA
            guard mode != 0 else { return illegal(op) }
            let r = reg(); bus.write(address(), r); setNZ(r); v = false; return storeCycles[mode]
        case 0x8:  // EOR
            let r = reg() ^ bus.read(address()); setReg(r); setNZ(r); v = false; return accCycles[mode]
        case 0x9:  // ADC
            setReg(add(reg(), bus.read(address()), carry: c)); return accCycles[mode]
        case 0xA:  // ORA
            let r = reg() | bus.read(address()); setReg(r); setNZ(r); v = false; return accCycles[mode]
        case 0xB:  // ADD
            setReg(add(reg(), bus.read(address()), carry: false)); return accCycles[mode]
        case 0xC:  // CPX(A 側のみ)
            guard isA else { return illegal(op) }
            let m = word()
            let r = x &- m
            n = r & 0x8000 != 0
            z = r == 0
            v = ((x ^ m) & (x ^ r) & 0x8000) != 0
            return wordCycles[mode]
        case 0xD:  // BSR / JSR(A 側のみ)
            guard isA, mode != 1 else { return illegal(op) }
            if mode == 0 {
                let offset = Int8(bitPattern: fetch())
                pushPC()
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 8
            }
            let target = address()
            pushPC()
            pc = target
            return mode == 2 ? 8 : 9
        case 0xE:  // LDS(A 側)/ LDX(B 側)
            let m = word()
            if isA { sp = m } else { x = m }
            setNZ16(m); v = false
            return wordCycles[mode]
        default:  // 0xF STS(A 側)/ STX(B 側)
            guard mode != 0 else { return illegal(op) }
            let value = isA ? sp : x
            write16(address(), value)
            setNZ16(value); v = false
            return wordStoreCycles[mode]
        }
    }
}
