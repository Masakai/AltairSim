import AltairCore
import SwiftUI

// 実機フロントパネル(Altair 8800b の写真)をもとにした配色と配置。
// 設計座標は 1000 x 460。表示幅に応じた倍率(panelScale)をすべての寸法に掛けて描くので、拡大しても文字がぼけない。
private enum Palette {
    static let frame = Color(red: 0.16, green: 0.44, blue: 0.66)
    static let frameDark = Color(red: 0.09, green: 0.28, blue: 0.45)
    static let plate = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let gold = Color(red: 0.80, green: 0.68, blue: 0.38)
    static let cream = Color(red: 0.84, green: 0.85, blue: 0.66)
    static let slate = Color(red: 0.55, green: 0.66, blue: 0.70)
    static let ink = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let label = Color(red: 0.90, green: 0.90, blue: 0.82)
    static let ledOn = Color(red: 1.0, green: 0.22, blue: 0.16)
    static let ledOff = Color(red: 0.33, green: 0.06, blue: 0.06)
}

private enum Layout {
    static let width: CGFloat = 1000
    static let height: CGFloat = 460

    /// A15...A0 の列位置(8進3ビットの区切りで間隔が広がる)
    static let columnX: [CGFloat] = [
        247, 301, 336, 371, 425, 460, 495, 548, 583, 619, 673, 708, 742, 795, 830, 865,
    ]
    /// A15-A8 と A7-A0 の境目
    static let splitX: CGFloat = 565
    static let stripLeft: CGFloat = 180
    static let stripRight: CGFloat = 889

    static let statusX: [CGFloat] = [222, 257, 292, 327, 362, 397, 432, 467]
    static let ledRow1: CGFloat = 74
    static let ledRow2: CGFloat = 142
    static let labelRow1: CGFloat = 98
    static let labelRow2: CGFloat = 168
    static let addressStrip: ClosedRange<CGFloat> = 178...214
    static let senseStrip: ClosedRange<CGFloat> = 220...268
    static let controlStrip: ClosedRange<CGFloat> = 282...372
}

private struct PanelScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    fileprivate var panelScale: CGFloat {
        get { self[PanelScaleKey.self] }
        set { self[PanelScaleKey.self] = newValue }
    }
}

// MARK: 部品

private struct PText: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = Palette.label
    var weight: Font.Weight = .regular
    @Environment(\.panelScale) private var s

    init(_ text: String, size: CGFloat = 11, color: Color = Palette.label, weight: Font.Weight = .regular) {
        self.text = text
        self.size = size
        self.color = color
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .font(.system(size: size * s, weight: weight))
            .foregroundStyle(color)
            .fixedSize()
    }
}

private struct PanelLED: View {
    let on: Bool
    @Environment(\.panelScale) private var s
    var body: some View {
        Circle()
            .fill(on ? Palette.ledOn : Palette.ledOff)
            .frame(width: 13 * s, height: 13 * s)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: s))
            .shadow(color: on ? Palette.ledOn.opacity(0.9) : .clear, radius: 6 * s)
    }
}

private struct RingLED: View {
    let on: Bool
    @Environment(\.panelScale) private var s
    var body: some View {
        Circle()
            .stroke(Palette.label, lineWidth: 2 * s)
            .frame(width: 22 * s, height: 22 * s)
            .overlay(
                Circle().fill(on ? Palette.ledOn : Color.clear).frame(width: 14 * s, height: 14 * s)
                    .shadow(color: on ? Palette.ledOn.opacity(0.9) : .clear, radius: 6 * s)
            )
    }
}

/// トグルの金属レバー(上向き = 正の符号の逆。offset の y が負で上)
private struct Lever: View {
    let offsetY: CGFloat
    @Environment(\.panelScale) private var s
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.35)).frame(width: 16 * s, height: 16 * s)
            Circle().stroke(Color.black, lineWidth: s).frame(width: 16 * s, height: 16 * s)
            RoundedRectangle(cornerRadius: 2 * s)
                .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.55)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 6 * s, height: 20 * s)
                .offset(y: offsetY * s)
        }
    }
}

/// 2 位置トグル(センススイッチと電源)。上 = 1 / ON。
private struct Toggle2: View {
    let on: Bool
    let action: () -> Void
    @Environment(\.panelScale) private var s
    var body: some View {
        Button(action: action) {
            Lever(offsetY: on ? -10 : 10)
                .frame(width: 26 * s, height: 44 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 3 位置トグル。上半分・下半分のクリックでそれぞれの側に倒れ、離すと中央に戻る。
/// latchedDown が非 nil のときは倒れたまま保持される(STOP/RUN)。
private struct SpringToggle: View {
    var latchedDown: Bool? = nil
    let onTop: () -> Void
    let onBottom: () -> Void
    @State private var pressed = 0  // -1 上, 0 中央, 1 下
    @Environment(\.panelScale) private var s

    var body: some View {
        let deflection: CGFloat = latchedDown.map { $0 ? 10 : -10 } ?? CGFloat(pressed) * 10
        Lever(offsetY: deflection)
            .frame(width: 34 * s, height: 46 * s)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard pressed == 0 else { return }
                        if v.startLocation.y < 23 * s {
                            pressed = -1
                            onTop()
                        } else {
                            pressed = 1
                            onBottom()
                        }
                    }
                    .onEnded { _ in pressed = 0 }
            )
    }
}

// MARK: パネル本体

struct FrontPanelView: View {
    @ObservedObject var model: SimulatorModel

    var body: some View {
        GeometryReader { geo in
            Panel(model: model)
                .environment(\.panelScale, geo.size.width / Layout.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(Layout.width / Layout.height, contentMode: .fit)
    }
}

private struct Panel: View {
    @ObservedObject var model: SimulatorModel
    @Environment(\.panelScale) private var s

    private func lit(_ st: CycleStatus) -> Bool { model.powered && model.status.contains(st) }
    private var waitOn: Bool { model.powered && !model.running }

    /// 設計座標で配置するためのヘルパー
    private func at<V: View>(_ x: CGFloat, _ y: CGFloat, _ view: V) -> some View {
        view.position(x: x * s, y: y * s)
    }

    /// 設計座標の矩形(x 範囲・y 範囲)
    private func box(_ xs: ClosedRange<CGFloat>, _ ys: ClosedRange<CGFloat>) -> some View {
        Rectangle()
            .frame(width: (xs.upperBound - xs.lowerBound) * s, height: (ys.upperBound - ys.lowerBound) * s)
            .position(x: (xs.lowerBound + xs.upperBound) / 2 * s, y: (ys.lowerBound + ys.upperBound) / 2 * s)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            housing
            ledRows
            addressAndSense
            controlStrip
            footer
        }
    }

    // MARK: 筐体

    private var housing: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8 * s).fill(Palette.frame)
            RoundedRectangle(cornerRadius: 8 * s).stroke(Palette.frameDark, lineWidth: 3 * s)
            box(16...984, 16...444).foregroundStyle(Palette.plate)
            box(24...976, 24...436).foregroundStyle(.clear)
                .overlay(
                    Rectangle().stroke(Palette.gold, lineWidth: 1.5 * s)
                        .frame(width: 952 * s, height: 412 * s)
                        .position(x: 500 * s, y: 230 * s)
                )
        }
    }

    // MARK: LED 部

    private var ledRows: some View {
        let x = Layout.columnX
        let sx = Layout.statusX
        let statusItems: [(String, CycleStatus?)] = [
            ("MEMR", .memr), ("INP", .inp), ("MI", .m1), ("OUT", .out),
            ("HLTA", .hlta), ("STACK", .stack), ("WO", .wo), ("INT", nil),
        ]
        return ZStack(alignment: .topLeading) {
            // 上段: PROTECT / INTE
            at(104, Layout.ledRow1, RingLED(on: false))
            at(104, Layout.labelRow1, PText("PROTECT", size: 9))
            at(156, Layout.ledRow1, PanelLED(on: model.powered && model.inte))
            at(156, Layout.labelRow1, PText("INTE", size: 9))

            // STATUS 枠
            at(
                (sx[0] + sx[7]) / 2, 99,
                RoundedRectangle(cornerRadius: 4 * s)
                    .stroke(Palette.gold, lineWidth: 1.5 * s)
                    .frame(width: (sx[7] - sx[0] + 48) * s, height: 26 * s)
            )
            ForEach(Array(statusItems.enumerated()), id: \.offset) { i, item in
                let on = item.1.map { lit($0) } ?? false
                at(sx[i], Layout.ledRow1, PanelLED(on: on))
                at(sx[i], 99, PText(item.0, size: 9))
            }
            at(sx[7] - 6, 124, PText("STATUS", size: 8))

            // DATA D7...D0(A7...A0 の列に合わせる)
            box(Layout.splitX...Layout.stripRight, 86...112).foregroundStyle(Palette.slate)
            ForEach(0..<8, id: \.self) { i in
                let bit = 7 - i
                at(x[8 + i], Layout.ledRow1, PanelLED(on: model.powered && model.dataLED & (1 << UInt8(bit)) != 0))
                at(x[8 + i], 99, PText("D\(bit)", size: 10, color: Palette.ink))
            }
            at(Layout.stripRight - 20, 124, PText("DATA", size: 8))

            // 下段: WAIT / HLDA / ADDRESS
            at(104, Layout.ledRow2, RingLED(on: waitOn))
            at(104, Layout.labelRow2, PText("WAIT", size: 9))
            at(156, Layout.ledRow2, PanelLED(on: false))
            at(156, Layout.labelRow2, PText("HLDA", size: 9))
            ForEach(0..<16, id: \.self) { i in
                at(x[i], Layout.ledRow2, PanelLED(on: model.powered && model.addressLED & (1 << UInt16(15 - i)) != 0))
            }
        }
    }

    // MARK: アドレスラベルとセンススイッチ

    private var addressAndSense: some View {
        let x = Layout.columnX
        let addr = Layout.addressStrip
        let sense = Layout.senseStrip
        let addrMid = (addr.lowerBound + addr.upperBound) / 2
        let senseMid = (sense.lowerBound + sense.upperBound) / 2
        return ZStack(alignment: .topLeading) {
            box(Layout.stripLeft...Layout.splitX, addr).foregroundStyle(Palette.cream)
            box(Layout.splitX...Layout.stripRight, addr).foregroundStyle(Palette.slate)
            box(Layout.stripLeft...Layout.splitX, sense).foregroundStyle(Palette.cream)
            box(Layout.splitX...Layout.stripRight, sense).foregroundStyle(Palette.slate)

            at(206, addrMid - 7, PText("MEMORY", size: 7, color: Palette.ink))
            at(197, addrMid + 6, PText("I/O", size: 7, color: Palette.ink))
            at(197, senseMid, PText("SENSE", size: 7, color: Palette.ink))

            ForEach(0..<16, id: \.self) { i in
                let bit = 15 - i
                if bit >= 8 {
                    at(x[i], addrMid - 6, PText("A\(bit)", size: 10, color: Palette.ink))
                    at(x[i], addrMid + 8, PText("(A\(bit - 8))", size: 8, color: Palette.ink))
                } else {
                    at(x[i], addrMid, PText("A\(bit)", size: 10, color: Palette.ink))
                }
                at(x[i], senseMid, Toggle2(on: model.switches & (1 << UInt16(bit)) != 0) {
                    model.toggleSwitch(bit)
                })
            }
        }
    }

    // MARK: 操作スイッチ帯

    private var controlStrip: some View {
        let ys = Layout.controlStrip
        let mid = (ys.lowerBound + ys.upperBound) / 2
        let topY = mid - 28
        let botY = mid + 28
        let xs: [CGFloat] = [250, 322, 394, 466, 538, 610]
        let labels: [(String, String)] = [
            ("STOP", "RUN"), ("SINGLE STEP", "SLOW"), ("EXAMINE", "EX NEXT"),
            ("DEPOSIT", "DEP NEXT"), ("RESET", "EXT CLR"), ("PROTECT", "UNPROTECT"),
        ]
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4 * s).fill(Palette.gold)
                .frame(width: (670 - 60) * s, height: (ys.upperBound - ys.lowerBound) * s)
                .position(x: (60 + 670) / 2 * s, y: mid * s)

            // 電源
            at(100, topY, PText("ON", size: 9, color: Palette.ink))
            at(100, mid, Toggle2(on: model.powered) { model.setPower(!model.powered) })
            at(100, botY, PText("OFF", size: 9, color: Palette.ink))
            at(158, mid, PText("POWER", size: 9, color: Palette.ink))

            ForEach(0..<6, id: \.self) { i in
                at(xs[i], topY, PText(labels[i].0, size: 9, color: Palette.ink))
                at(xs[i], botY, PText(labels[i].1, size: 9, color: Palette.ink))
            }
            at(xs[0], mid, SpringToggle(latchedDown: model.running,
                                        onTop: { model.stopRun(run: false) },
                                        onBottom: { model.stopRun(run: true) }))
            at(xs[1], mid, SpringToggle(onTop: model.singleStep, onBottom: {}))
            at(xs[2], mid, SpringToggle(onTop: model.examine, onBottom: model.examineNext))
            at(xs[3], mid, SpringToggle(onTop: model.deposit, onBottom: model.depositNext))
            at(xs[4], mid, SpringToggle(onTop: model.reset, onBottom: model.extClear))
            at(xs[5], mid, SpringToggle(onTop: {}, onBottom: {}))
        }
    }

    // MARK: ロゴ

    private var footer: some View {
        ZStack(alignment: .topLeading) {
            at(90, 410, Image(systemName: "hexagon.fill").font(.system(size: 30 * s)).foregroundStyle(Palette.frame))
            at(152, 410, Text("mits").font(.system(size: 26 * s, weight: .heavy, design: .rounded)).foregroundStyle(Palette.cream))
            // 右端を DATA 帯の右端(889)に合わせる
            Text("altair 8800")
                .font(.system(size: 34 * s, weight: .heavy, design: .rounded).italic())
                .foregroundStyle(Palette.cream)
                .fixedSize()
                .frame(width: 300 * s, alignment: .trailing)
                .position(x: (Layout.stripRight - 150) * s, y: 410 * s)
        }
    }
}
