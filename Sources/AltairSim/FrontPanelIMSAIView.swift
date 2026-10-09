import AltairCore
import SwiftUI

// IMSAI 8080 のフロントパネル(CP-A)。設計座標は 1000 x 400。
// 配置は実機の写真(deramp.com の IMSAI_8080.jpg、CP-A 基板の Front Panel-1.JPG)と、CP-A のマニュアルから起こした:
// - 左: プログラム出力 LED(8)、ステータスバイト LED(8)、アドレス LED A15〜A8(8)と、その下に A15〜A8 のパドルスイッチ(青 4、赤 4)
// - 中: データバス LED(8)、アドレス LED A7〜A0(8)と、その下に A7〜A0 のパドルスイッチ(青 4、赤 4)
// - 右: INTERRUPT ENABLED / RUN / WAIT / HOLD の LED と、制御用のパドル 6 個(青赤が交互)
// - 右上: 白い「IMSAI 8080」のロゴ
private enum PI {
    static let width: CGFloat = 1000
    static let height: CGFloat = 400
    static let caseColor = Color(red: 0.43, green: 0.55, blue: 0.70)
    static let caseEdge = Color(red: 0.25, green: 0.34, blue: 0.47)
    static let mask = Color(red: 0.05, green: 0.06, blue: 0.07)
    static let label = Color(red: 0.88, green: 0.88, blue: 0.85)
    static let ledOn = Color(red: 1.0, green: 0.22, blue: 0.16)
    static let ledOff = Color(red: 0.30, green: 0.05, blue: 0.06)
    static let paddleBlue = Color(red: 0.43, green: 0.43, blue: 0.82)
    static let paddleBlueDark = Color(red: 0.30, green: 0.30, blue: 0.62)
    static let paddleRed = Color(red: 0.90, green: 0.27, blue: 0.17)
    static let paddleRedDark = Color(red: 0.68, green: 0.17, blue: 0.10)

    static let leftX: [CGFloat] = (0..<8).map { 88 + CGFloat($0) * 36.5 }
    static let middleX: [CGFloat] = (0..<8).map { 428 + CGFloat($0) * 36.5 }
    static let rightX: [CGFloat] = (0..<6).map { 745 + CGFloat($0) * 41 }

    static let outLEDY: CGFloat = 92
    static let outLabelY: CGFloat = 108
    static let statusLabelY: CGFloat = 128
    static let statusLEDY: CGFloat = 148
    static let scaleY: CGFloat = 172
    static let addrLEDY: CGFloat = 198
    static let switchLabelY: CGFloat = 228
    static let paddleY: CGFloat = 300
}

private struct ScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    fileprivate var imsaiScale: CGFloat {
        get { self[ScaleKey.self] }
        set { self[ScaleKey.self] = newValue }
    }
}

private struct LEDI: View {
    let on: Bool
    @Environment(\.imsaiScale) private var s
    var body: some View {
        Circle()
            .fill(on ? PI.ledOn : PI.ledOff)
            .frame(width: 11 * s, height: 11 * s)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: s))
            .shadow(color: on ? PI.ledOn.opacity(0.9) : .clear, radius: 6 * s)
    }
}

private struct LabelI: View {
    let text: String
    var size: CGFloat = 9
    var bold = false
    @Environment(\.imsaiScale) private var s
    var body: some View {
        Text(text)
            .font(.custom("Helvetica Neue", size: size * s).weight(bold ? .bold : .regular))
            .foregroundStyle(PI.label)
            .fixedSize()
    }
}

/// パドルスイッチ。上半分を押すと「上」、下半分を押すと「下」の動作になる。
/// latched = true なら、押した位置のまま残る(RUN/STOP、電源)。false は、離すと中央に戻る(EXAMINE、DEPOSIT、RESET、SINGLE STEP)。
private struct Paddle: View {
    let blue: Bool
    /// 上に倒れているとき(latched の表示)
    let up: Bool
    let latched: Bool
    let upAction: () -> Void
    let downAction: () -> Void
    @State private var pressedUp: Bool?
    @Environment(\.imsaiScale) private var s

    private var shown: Bool? { latched ? up : pressedUp }

    var body: some View {
        ZStack {
            // 台座
            RoundedRectangle(cornerRadius: 2 * s).fill(Color(white: 0.16)).frame(width: 30 * s, height: 62 * s)
            // パドル本体: 手前に倒れた側が明るく、反対側が暗い
            VStack(spacing: 0) {
                Rectangle().fill(blue ? (shown == true ? PI.paddleBlue : PI.paddleBlueDark) : (shown == true ? PI.paddleRed : PI.paddleRedDark))
                Rectangle().fill(blue ? (shown == false ? PI.paddleBlue : PI.paddleBlueDark) : (shown == false ? PI.paddleRed : PI.paddleRedDark))
            }
            .frame(width: 26 * s, height: shown == nil ? 36 * s : 54 * s)
            .offset(y: (shown == true ? -8 : (shown == false ? 8 : 0)) * s)
            .overlay(
                Rectangle().stroke(Color.black.opacity(0.4), lineWidth: s)
                    .frame(width: 26 * s, height: shown == nil ? 36 * s : 54 * s)
                    .offset(y: (shown == true ? -8 : (shown == false ? 8 : 0)) * s)
            )
        }
        .frame(width: 34 * s, height: 66 * s)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard pressedUp == nil else { return }
                    let isUp = v.startLocation.y < 33 * s
                    pressedUp = isUp
                    isUp ? upAction() : downAction()
                }
                .onEnded { _ in pressedUp = nil }
        )
    }
}

struct FrontPanelIMSAIView: View {
    @ObservedObject var model: SimulatorModel

    var body: some View {
        GeometryReader { geo in
            IMSAIPanel(model: model)
                .environment(\.imsaiScale, geo.size.width / PI.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(PI.width / PI.height, contentMode: .fit)
    }
}

private struct IMSAIPanel: View {
    @ObservedObject var model: SimulatorModel
    @Environment(\.imsaiScale) private var s

    private func at<V: View>(_ x: CGFloat, _ y: CGFloat, _ view: V) -> some View {
        view.position(x: x * s, y: y * s)
    }

    private var lit: Bool { model.powered }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6 * s).fill(PI.caseColor)
            RoundedRectangle(cornerRadius: 6 * s).stroke(PI.caseEdge, lineWidth: 3 * s)
            // 黒いアクリルのマスク
            RoundedRectangle(cornerRadius: 3 * s).fill(PI.mask)
                .frame(width: 960 * s, height: 370 * s)
                .position(x: 500 * s, y: 200 * s)

            outputRow
            statusRow
            leftAddressRow
            middleRows
            rightGroup
            logo
        }
    }

    // MARK: 左のグループ

    /// プログラム出力 LED(ポート FF)。ハードは反転して点灯するので、書いた値のビットが 0 のとき点灯する
    private var outputRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                let bit = 7 - i
                at(PI.leftX[i], PI.outLEDY, LEDI(on: lit && model.imsaiProgrammedOutput & (1 << UInt8(bit)) == 0))
                at(PI.leftX[i], PI.outLabelY, LabelI(text: "\(bit)"))
            }
            at(PI.middleX[0] - 40, PI.outLEDY - 4, LabelI(text: "PROGRAMMED", size: 8))
            at(PI.middleX[0] - 40, PI.outLEDY + 6, LabelI(text: "OUTPUT", size: 8))
        }
    }

    /// ステータスバイト LED(8080 のステータスワード D7〜D0 の並び)
    private var statusRow: some View {
        let names = ["MEMR", "INP", "M1", "OUT", "HLTA", "STACK", "WO", "INTA"]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                at(PI.leftX[i], PI.statusLabelY, LabelI(text: names[i], size: 8))
                at(PI.leftX[i], PI.statusLEDY, LEDI(on: lit && statusBit(i)))
            }
            at(PI.middleX[0] - 40, PI.statusLEDY - 4, LabelI(text: "STATUS", size: 8))
            at(PI.middleX[0] - 40, PI.statusLEDY + 6, LabelI(text: "BYTE", size: 8))
        }
    }

    /// i は左から 0〜7(MEMR、INP、M1、OUT、HLTA、STACK、WO、INTA)
    private func statusBit(_ i: Int) -> Bool {
        let st = model.status
        switch i {
        case 0: return st.contains(.memr)
        case 1: return st.contains(.inp)
        case 2: return st.contains(.m1)
        case 3: return st.contains(.out)
        case 4: return st.contains(.hlta)
        case 5: return st.contains(.stack)
        case 6: return st.contains(.wo)      // WO は負論理: 書き込みサイクル以外で点灯(CycleStatus が実機どおりに持つ)
        default: return false                // INTA(割り込み応答)は未実装
        }
    }

    /// アドレス LED A15〜A8 と、パドル A15〜A8
    private var leftAddressRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                let bit = 15 - i
                at(PI.leftX[i], PI.addrLEDY, LEDI(on: lit && model.addressLED & (1 << UInt16(bit)) != 0))
                at(PI.leftX[i], PI.switchLabelY, LabelI(text: "\(bit)"))
                at(PI.leftX[i], PI.paddleY, addressPaddle(bit: bit, blue: i < 4))
            }
            at(PI.leftX[0] + 120, 247, LabelI(text: "ADDRESS-PROGRAMMED INPUT", size: 8))
            bracket(PI.leftX[0] - 12, PI.leftX[7] + 12, PI.scaleY)
            at(PI.middleX[0] - 40, PI.addrLEDY, LabelI(text: "ADDRESS", size: 8))
            at(PI.middleX[0] - 40, PI.addrLEDY + 10, LabelI(text: "BUS", size: 8))
        }
    }

    // MARK: 中のグループ

    /// データバス LED(上、y = ステータス行)、アドレス LED A7〜A0(下)と、パドル A7〜A0(データスイッチも兼ねる)
    private var middleRows: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                let bit = 7 - i
                at(PI.middleX[i], PI.statusLabelY, LabelI(text: "\(bit)"))
                at(PI.middleX[i], PI.statusLEDY, LEDI(on: lit && model.dataLED & (1 << UInt8(bit)) != 0))
                at(PI.middleX[i], PI.addrLEDY, LEDI(on: lit && model.addressLED & (1 << UInt16(bit)) != 0))
                at(PI.middleX[i], PI.switchLabelY, LabelI(text: "\(bit)"))
                at(PI.middleX[i], PI.paddleY, addressPaddle(bit: bit, blue: i < 4))
            }
            at(PI.middleX[7] + 56, PI.statusLEDY - 4, LabelI(text: "DATA", size: 8))
            at(PI.middleX[7] + 56, PI.statusLEDY + 6, LabelI(text: "BUS", size: 8))
            at(PI.middleX[7] + 56, PI.addrLEDY - 4, LabelI(text: "ADDRESS", size: 8))
            at(PI.middleX[7] + 56, PI.addrLEDY + 6, LabelI(text: "BUS", size: 8))
            at(PI.middleX[0] + 112, 247, LabelI(text: "ADDRESS-DATA", size: 8))
            bracket(PI.middleX[0] - 12, PI.middleX[7] + 12, PI.scaleY)
        }
    }

    private func addressPaddle(bit: Int, blue: Bool) -> some View {
        let on = model.swIMSAI & (1 << UInt16(bit)) != 0
        return Paddle(blue: blue, up: on, latched: true,
                      upAction: { if !on { model.toggleIMSAISwitch(bit) } },
                      downAction: { if on { model.toggleIMSAISwitch(bit) } })
    }

    // MARK: 右のグループ

    private var rightGroup: some View {
        let functions: [(top: String, bottom: String)] = [
            ("EXAMINE", "EXAMINE NEXT"), ("DEPOSIT", "DEPOSIT NEXT"), ("RESET", "EXT CLR"),
            ("RUN", "STOP"), ("SINGLE STEP", ""), ("PWR ON", "PWR OFF"),
        ]
        return ZStack(alignment: .topLeading) {
            // INTERRUPT ENABLED / RUN / WAIT / HOLD
            at(790, 178, LabelI(text: "INTERRUPT", size: 7))
            at(790, 187, LabelI(text: "ENABLED", size: 7))
            at(790, 198, LEDI(on: lit && model.inte))
            at(845, 182, LabelI(text: "RUN", size: 8))
            at(845, 198, LEDI(on: lit && model.running))
            at(895, 182, LabelI(text: "WAIT", size: 8))
            at(895, 198, LEDI(on: lit && !model.running))
            at(945, 182, LabelI(text: "HOLD", size: 8))
            at(945, 198, LEDI(on: false))

            ForEach(0..<6, id: \.self) { j in
                // 長い名前は 2 行に分ける(列の間隔は 41 しかない)
                let top = functions[j].top.split(separator: " ").map(String.init)
                let bottom = functions[j].bottom.split(separator: " ").map(String.init)
                ForEach(Array(top.enumerated()), id: \.offset) { k, w in
                    at(PI.rightX[j], 222 + CGFloat(k) * 8, LabelI(text: w, size: 6.5))
                }
                ForEach(Array(bottom.enumerated()), id: \.offset) { k, w in
                    at(PI.rightX[j], 242 + CGFloat(k) * 8, LabelI(text: w, size: 6.5))
                }
            }
            // 制御パドル(青赤が交互)
            at(PI.rightX[0], PI.paddleY, Paddle(blue: true, up: false, latched: false,
                                                 upAction: { model.imsaiExamine(next: false) }, downAction: { model.imsaiExamine(next: true) }))
            at(PI.rightX[1], PI.paddleY, Paddle(blue: false, up: false, latched: false,
                                                 upAction: { model.imsaiDeposit(next: false) }, downAction: { model.imsaiDeposit(next: true) }))
            at(PI.rightX[2], PI.paddleY, Paddle(blue: true, up: false, latched: false,
                                                 upAction: { model.imsaiReset() }, downAction: { model.imsaiExtClear() }))
            at(PI.rightX[3], PI.paddleY, Paddle(blue: false, up: model.running, latched: true,
                                                 upAction: { model.imsaiRun(true) }, downAction: { model.imsaiRun(false) }))
            at(PI.rightX[4], PI.paddleY, Paddle(blue: true, up: false, latched: false,
                                                 upAction: { model.imsaiSingleStep() }, downAction: { model.imsaiSingleStep() }))
            at(PI.rightX[5], PI.paddleY, Paddle(blue: false, up: model.powered, latched: true,
                                                 upAction: { model.setPower(true) }, downAction: { model.setPower(false) }))
        }
    }

    // MARK: ロゴ

    private var logo: some View {
        ZStack(alignment: .topLeading) {
            Text("IMSAI 8080")
                .font(.custom("Helvetica Neue", size: 64 * s).weight(.heavy))
                .foregroundStyle(Color.white.opacity(0.95))
                .fixedSize()
                .position(x: 762 * s, y: 60 * s)
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 330 * s, height: 2 * s).position(x: 762 * s, y: 94 * s)
            Text("MICROCOMPUTER SYSTEM")
                .font(.custom("Helvetica Neue", size: 7 * s))
                .foregroundStyle(PI.label)
                .position(x: 880 * s, y: 102 * s)
        }
    }

    /// LED 列の下の白い目盛り線(両端が少し立ち上がる)
    private func bracket(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: x1 * s, y: (y - 4) * s))
            p.addLine(to: CGPoint(x: x1 * s, y: y * s))
            p.addLine(to: CGPoint(x: x2 * s, y: y * s))
            p.addLine(to: CGPoint(x: x2 * s, y: (y - 4) * s))
        }
        .stroke(PI.label.opacity(0.9), lineWidth: 1.2 * s)
    }
}
