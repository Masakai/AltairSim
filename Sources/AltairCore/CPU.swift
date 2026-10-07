/// CPU から見たメモリ・I/O ポートの口。
public protocol Bus: AnyObject {
    func read(_ addr: UInt16) -> UInt8
    func write(_ addr: UInt16, _ value: UInt8)
    func input(_ port: UInt8) -> UInt8
    func output(_ port: UInt8, _ value: UInt8)
    /// 命令フェッチ(M1 サイクル)
    func fetchOpcode(_ addr: UInt16) -> UInt8
    func readStack(_ addr: UInt16) -> UInt8
    func writeStack(_ addr: UInt16, _ value: UInt8)
}

extension Bus {
    public func fetchOpcode(_ addr: UInt16) -> UInt8 { read(addr) }
    public func readStack(_ addr: UInt16) -> UInt8 { read(addr) }
    public func writeStack(_ addr: UInt16, _ value: UInt8) { write(addr, value) }
}

/// Intel 8080 エミュレータ。命令単位で実行し、消費クロック数(T ステート)を返す。
public final class CPU {
    public var a: UInt8 = 0, b: UInt8 = 0, c: UInt8 = 0, d: UInt8 = 0
    public var e: UInt8 = 0, h: UInt8 = 0, l: UInt8 = 0
    public var sp: UInt16 = 0
    public var pc: UInt16 = 0
    public var sf = false, zf = false, acf = false, pf = false, cf = false
    public var inte = false
    public var halted = false

    private unowned let bus: Bus

    public init(bus: Bus) {
        self.bus = bus
    }

    public func reset() {
        pc = 0
        halted = false
        inte = false
    }

    // MARK: レジスタアクセス

    public var bc: UInt16 {
        get { UInt16(b) << 8 | UInt16(c) }
        set { b = UInt8(newValue >> 8); c = UInt8(newValue & 0xFF) }
    }
    public var de: UInt16 {
        get { UInt16(d) << 8 | UInt16(e) }
        set { d = UInt8(newValue >> 8); e = UInt8(newValue & 0xFF) }
    }
    public var hl: UInt16 {
        get { UInt16(h) << 8 | UInt16(l) }
        set { h = UInt8(newValue >> 8); l = UInt8(newValue & 0xFF) }
    }

    /// フラグバイト: S Z 0 AC 0 P 1 CY
    public var flags: UInt8 {
        get {
            (sf ? 0x80 : 0) | (zf ? 0x40 : 0) | (acf ? 0x10 : 0)
                | (pf ? 0x04 : 0) | 0x02 | (cf ? 0x01 : 0)
        }
        set {
            sf = newValue & 0x80 != 0
            zf = newValue & 0x40 != 0
            acf = newValue & 0x10 != 0
            pf = newValue & 0x04 != 0
            cf = newValue & 0x01 != 0
        }
    }

    /// レジスタ番号 0..7 = B C D E H L M A
    private func getR(_ i: UInt8) -> UInt8 {
        switch i {
        case 0: return b
        case 1: return c
        case 2: return d
        case 3: return e
        case 4: return h
        case 5: return l
        case 6: return bus.read(hl)
        default: return a
        }
    }

    private func setR(_ i: UInt8, _ v: UInt8) {
        switch i {
        case 0: b = v
        case 1: c = v
        case 2: d = v
        case 3: e = v
        case 4: h = v
        case 5: l = v
        case 6: bus.write(hl, v)
        default: a = v
        }
    }

    /// レジスタペア 0..3 = BC DE HL SP
    private func getRP(_ i: UInt8) -> UInt16 {
        switch i {
        case 0: return bc
        case 1: return de
        case 2: return hl
        default: return sp
        }
    }

    private func setRP(_ i: UInt8, _ v: UInt16) {
        switch i {
        case 0: bc = v
        case 1: de = v
        case 2: hl = v
        default: sp = v
        }
    }

    // MARK: メモリ補助

    private func fetchOpcode() -> UInt8 {
        let v = bus.fetchOpcode(pc)
        pc &+= 1
        return v
    }

    private func fetch() -> UInt8 {
        let v = bus.read(pc)
        pc &+= 1
        return v
    }

    private func fetch16() -> UInt16 {
        let lo = UInt16(fetch())
        let hi = UInt16(fetch())
        return hi << 8 | lo
    }

    private func read16(_ addr: UInt16) -> UInt16 {
        UInt16(bus.read(addr)) | UInt16(bus.read(addr &+ 1)) << 8
    }

    private func write16(_ addr: UInt16, _ v: UInt16) {
        bus.write(addr, UInt8(v & 0xFF))
        bus.write(addr &+ 1, UInt8(v >> 8))
    }

    private func push(_ v: UInt16) {
        sp &-= 1
        bus.writeStack(sp, UInt8(v >> 8))
        sp &-= 1
        bus.writeStack(sp, UInt8(v & 0xFF))
    }

    private func readStack16() -> UInt16 {
        UInt16(bus.readStack(sp)) | UInt16(bus.readStack(sp &+ 1)) << 8
    }

    private func pop() -> UInt16 {
        let v = readStack16()
        sp &+= 2
        return v
    }

    // MARK: フラグ・演算

    private func setSZP(_ v: UInt8) {
        sf = v & 0x80 != 0
        zf = v == 0
        pf = v.nonzeroBitCount % 2 == 0
    }

    /// op: 0 ADD, 1 ADC, 2 SUB, 3 SBC, 4 ANA, 5 XRA, 6 ORA, 7 CMP
    private func alu(_ op: UInt8, _ v: UInt8) {
        switch op {
        case 0, 1:
            let carry: Int = (op == 1 && cf) ? 1 : 0
            let r = Int(a) + Int(v) + carry
            acf = (Int(a & 0xF) + Int(v & 0xF) + carry) > 0xF
            cf = r > 0xFF
            a = UInt8(r & 0xFF)
            setSZP(a)
        case 2, 3, 7:
            // 8080 は減算を「補数の加算」で行い、キャリーを反転して扱う
            let borrow: Int = (op == 3 && cf) ? 1 : 0
            let r = Int(a) - Int(v) - borrow
            acf = (Int(a & 0xF) + Int(~v & 0xF) + (1 - borrow)) > 0xF
            cf = r < 0
            let res = UInt8(truncatingIfNeeded: r)
            setSZP(res)
            if op != 7 { a = res }
        case 4:
            acf = ((a | v) & 0x08) != 0
            a &= v
            cf = false
            setSZP(a)
        case 5:
            a ^= v
            acf = false
            cf = false
            setSZP(a)
        default:
            a |= v
            acf = false
            cf = false
            setSZP(a)
        }
    }

    private func condition(_ cc: UInt8) -> Bool {
        switch cc {
        case 0: return !zf
        case 1: return zf
        case 2: return !cf
        case 3: return cf
        case 4: return !pf
        case 5: return pf
        case 6: return !sf
        default: return sf
        }
    }

    private func daa() {
        var adjust: UInt8 = 0
        var carry = cf
        if (a & 0x0F) > 9 || acf { adjust |= 0x06 }
        if a > 0x99 || cf {
            adjust |= 0x60
            carry = true
        }
        acf = Int(a & 0x0F) + Int(adjust & 0x0F) > 0x0F
        a = a &+ adjust
        cf = carry
        setSZP(a)
    }

    // MARK: 実行

    /// 1 命令を実行して消費クロック数を返す。HLT 後は 4 を返し続ける。
    @discardableResult
    public func step() -> Int {
        if halted { return 4 }
        let op = fetchOpcode()

        if op < 0x40 {
            return stepLow(op)
        }
        if op < 0x80 {
            if op == 0x76 {
                halted = true
                return 7
            }
            let dst = (op >> 3) & 7, src = op & 7
            setR(dst, getR(src))
            return (dst == 6 || src == 6) ? 7 : 5
        }
        if op < 0xC0 {
            let src = op & 7
            alu((op >> 3) & 7, getR(src))
            return src == 6 ? 7 : 4
        }
        return stepHigh(op)
    }

    private func stepLow(_ op: UInt8) -> Int {
        let rp = (op >> 4) & 3
        switch op & 7 {
        case 0:
            return 4  // NOP(未定義命令も NOP 扱い)
        case 1:
            if op & 8 == 0 {
                setRP(rp, fetch16())  // LXI
                return 10
            }
            let sum = Int(hl) + Int(getRP(rp))  // DAD
            cf = sum > 0xFFFF
            hl = UInt16(sum & 0xFFFF)
            return 10
        case 2:
            switch op {
            case 0x02: bus.write(bc, a); return 7
            case 0x0A: a = bus.read(bc); return 7
            case 0x12: bus.write(de, a); return 7
            case 0x1A: a = bus.read(de); return 7
            case 0x22: write16(fetch16(), hl); return 16
            case 0x2A: hl = read16(fetch16()); return 16
            case 0x32: bus.write(fetch16(), a); return 13
            default: a = bus.read(fetch16()); return 13  // 0x3A LDA
            }
        case 3:
            let v = getRP(rp)
            setRP(rp, op & 8 == 0 ? v &+ 1 : v &- 1)  // INX / DCX
            return 5
        case 4:
            let r = (op >> 3) & 7  // INR
            let v = getR(r)
            let res = v &+ 1
            acf = (v & 0x0F) == 0x0F
            setSZP(res)
            setR(r, res)
            return r == 6 ? 10 : 5
        case 5:
            let r = (op >> 3) & 7  // DCR
            let v = getR(r)
            let res = v &- 1
            acf = (v & 0x0F) != 0
            setSZP(res)
            setR(r, res)
            return r == 6 ? 10 : 5
        case 6:
            let r = (op >> 3) & 7  // MVI
            setR(r, fetch())
            return r == 6 ? 10 : 7
        default:
            switch (op >> 3) & 7 {
            case 0:  // RLC
                cf = a & 0x80 != 0
                a = a << 1 | (cf ? 1 : 0)
            case 1:  // RRC
                cf = a & 0x01 != 0
                a = a >> 1 | (cf ? 0x80 : 0)
            case 2:  // RAL
                let old = cf
                cf = a & 0x80 != 0
                a = a << 1 | (old ? 1 : 0)
            case 3:  // RAR
                let old = cf
                cf = a & 0x01 != 0
                a = a >> 1 | (old ? 0x80 : 0)
            case 4: daa()
            case 5: a = ~a  // CMA
            case 6: cf = true  // STC
            default: cf.toggle()  // CMC
            }
            return 4
        }
    }

    private func stepHigh(_ op: UInt8) -> Int {
        let cc = (op >> 3) & 7
        switch op & 7 {
        case 0:  // Rcc
            if condition(cc) {
                pc = pop()
                return 11
            }
            return 5
        case 1:
            if op & 8 == 0 {  // POP
                let v = pop()
                let rp = (op >> 4) & 3
                if rp == 3 {
                    a = UInt8(v >> 8)
                    flags = UInt8(v & 0xFF)
                } else {
                    setRP(rp, v)
                }
                return 10
            }
            switch op {
            case 0xC9, 0xD9: pc = pop(); return 10  // RET
            case 0xE9: pc = hl; return 5  // PCHL
            default: sp = hl; return 5  // SPHL
            }
        case 2:  // Jcc
            let target = fetch16()
            if condition(cc) { pc = target }
            return 10
        case 3:
            switch op {
            case 0xC3, 0xCB: pc = fetch16(); return 10  // JMP
            case 0xD3: bus.output(fetch(), a); return 10  // OUT
            case 0xDB: a = bus.input(fetch()); return 10  // IN
            case 0xE3:  // XTHL
                let v = readStack16()
                bus.writeStack(sp, l)
                bus.writeStack(sp &+ 1, h)
                hl = v
                return 18
            case 0xEB:  // XCHG
                let t = de
                de = hl
                hl = t
                return 4
            case 0xF3: inte = false; return 4
            default: inte = true; return 4  // 0xFB EI
            }
        case 4:  // Ccc
            let target = fetch16()
            if condition(cc) {
                push(pc)
                pc = target
                return 17
            }
            return 11
        case 5:
            if op & 8 == 0 {  // PUSH
                let rp = (op >> 4) & 3
                push(rp == 3 ? UInt16(a) << 8 | UInt16(flags) : getRP(rp))
                return 11
            }
            let target = fetch16()  // CALL
            push(pc)
            pc = target
            return 17
        case 6:
            alu(cc, fetch())
            return 7
        default:  // RST
            push(pc)
            pc = UInt16(cc) * 8
            return 11
        }
    }
}
