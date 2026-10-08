import AltairCore
import SwiftUI

// Altair 680 のフロントパネル(写真: 青い筐体、褐色がかった灰色のパネル、暗赤色の LED)をもとにした描画。
// 設計座標は 1000 x 430。FrontPanelView と同様に、表示幅に応じた倍率をすべての寸法に掛けて描く。
private enum P680 {
    static let width: CGFloat = 1000
    static let height: CGFloat = 404
    static let caseBlue = Color(red: 0.27, green: 0.57, blue: 0.77)
    static let caseEdge = Color(red: 0.16, green: 0.38, blue: 0.55)
    static let panel = Color(red: 0.27, green: 0.27, blue: 0.285)
    static let label = Color(red: 0.93, green: 0.93, blue: 0.90)
    static let ledOn = Color(red: 1.0, green: 0.20, blue: 0.15)
    static let ledOff = Color(red: 0.36, green: 0.06, blue: 0.07)
    static let logoBlue = Color(red: 0.31, green: 0.58, blue: 0.80)
    static let logoGray = Color(red: 0.78, green: 0.80, blue: 0.82)

    // 位置はすべて写真(MITS_Altair680b_sn11952.jpg)から測った値。前面板の内側 x 22〜768、y 150〜434(写真上)を、
    // 設計座標の x 18〜982、y 18〜386 に写している。
    /// アドレス A15...A0
    static let addressX: [CGFloat] = [99, 151, 200, 252, 304, 355, 407, 459, 527, 580, 632, 682, 734, 781, 829, 877]
    /// データ D7...D0(A7...A0 の列とほぼ揃う)
    static let dataX: [CGFloat] = [530, 586, 638, 690, 741, 794, 845, 895]
    static let dataLEDY: CGFloat = 83
    static let dataLabelY: CGFloat = 119
    static let dataSwitchY: CGFloat = 155
    static let dataBracketY: CGFloat = 174
    static let addressLEDY: CGFloat = 223
    static let addressLabelY: CGFloat = 254
    static let addressSwitchY: CGFloat = 287
    static let addressBracketY: CGFloat = 304
}

private struct ScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    fileprivate var p680Scale: CGFloat {
        get { self[ScaleKey.self] }
        set { self[ScaleKey.self] = newValue }
    }
}

private struct LED680: View {
    let on: Bool
    @Environment(\.p680Scale) private var s
    var body: some View {
        Circle()
            .fill(on ? P680.ledOn : P680.ledOff)
            .frame(width: 14 * s, height: 14 * s)
            .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1.2 * s))
            .overlay(
                Circle().fill(Color.white.opacity(on ? 0.55 : 0.22)).frame(width: 4 * s, height: 4 * s).offset(x: -2 * s, y: -2.5 * s)
            )
            .shadow(color: on ? P680.ledOn.opacity(0.9) : .clear, radius: 6 * s)
    }
}

private struct Label680: View {
    let text: String
    var size: CGFloat = 15
    @Environment(\.p680Scale) private var s
    var body: some View {
        Text(text).font(.custom("Helvetica Neue", size: size * s)).foregroundStyle(P680.label).fixedSize()
    }
}

private struct Lever680: View {
    let offsetY: CGFloat
    @Environment(\.p680Scale) private var s
    var body: some View {
        ZStack {
            // 写真では、各トグルの右下に長い影が落ちている
            RoundedRectangle(cornerRadius: 3 * s)
                .fill(Color.black.opacity(0.38))
                .frame(width: 7 * s, height: 26 * s)
                .blur(radius: 1.5 * s)
                .offset(x: 7 * s, y: (offsetY + 12) * s)
            // ナット(銀色)
            Circle().fill(RadialGradient(colors: [Color(white: 0.92), Color(white: 0.52)], center: .topLeading, startRadius: 0, endRadius: 12 * s))
                .frame(width: 17 * s, height: 17 * s)
            Circle().stroke(Color.black.opacity(0.55), lineWidth: s).frame(width: 17 * s, height: 17 * s)
            // バットハンドル(先端が細い)
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.58), Color(white: 0.80)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 7 * s, height: 24 * s)
                .overlay(Capsule().stroke(Color.black.opacity(0.3), lineWidth: 0.6 * s))
                .offset(y: offsetY * s)
        }
    }
}

/// 2 位置のトグル(上 = 1)
private struct Toggle680: View {
    let on: Bool
    let action: () -> Void
    @Environment(\.p680Scale) private var s
    var body: some View {
        Button(action: action) {
            Lever680(offsetY: on ? -9 : 9)
                .frame(width: 34 * s, height: 50 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 押している間だけ倒れるトグル(RESET、DEP)。上下どちらを押しても動作する。
private struct Momentary680: View {
    let action: () -> Void
    @State private var pressed = false
    @Environment(\.p680Scale) private var s
    var body: some View {
        Lever680(offsetY: pressed ? 9 : 0)
            .frame(width: 34 * s, height: 50 * s)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                    }
                    .onEnded { _ in pressed = false }
            )
    }
}

struct FrontPanel680View: View {
    @ObservedObject var model: SimulatorModel

    var body: some View {
        GeometryReader { geo in
            Panel(model: model)
                .environment(\.p680Scale, geo.size.width / P680.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(P680.width / P680.height, contentMode: .fit)
    }
}

private struct Panel: View {
    @ObservedObject var model: SimulatorModel
    @Environment(\.p680Scale) private var s

    private func at<V: View>(_ x: CGFloat, _ y: CGFloat, _ view: V) -> some View {
        view.position(x: x * s, y: y * s)
    }

    private var lit: Bool { model.powered }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 筐体(明るい青)と前面板(暗い灰色)
            RoundedRectangle(cornerRadius: 5 * s).fill(P680.caseBlue)
            RoundedRectangle(cornerRadius: 5 * s).stroke(P680.caseEdge, lineWidth: 2.5 * s)
            Rectangle().fill(P680.panel)
                .frame(width: 964 * s, height: 368 * s)
                .position(x: 500 * s, y: 202 * s)
            Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 1.5 * s)
                .frame(width: 964 * s, height: 368 * s)
                .position(x: 500 * s, y: 202 * s)
            ForEach([(49.0, 55.0), (965.0, 51.0), (101.0, 361.0), (915.0, 350.0)], id: \.0) { x, y in
                screw.position(x: x * s, y: y * s)
            }

            statusCluster
            dataRow
            addressRow
            logo
        }
    }

    private var screw: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45)], center: .topLeading, startRadius: 0, endRadius: 10 * s))
                .frame(width: 13 * s, height: 13 * s)
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 9 * s, height: 1.5 * s).rotationEffect(.degrees(35))
        }
    }

    /// LED とラベルの間の短い目盛り線
    private func tick(_ x: CGFloat, _ y: CGFloat) -> some View {
        Rectangle().fill(P680.label.opacity(0.8)).frame(width: 1.2 * s, height: 6 * s).position(x: x * s, y: y * s)
    }

    /// 左上: AC / HLT / RUN の LED と、RESET / HLT-RUN / DEP のスイッチ
    private var statusCluster: some View {
        ZStack(alignment: .topLeading) {
            at(83, 70, Label680(text: "AC"))
            at(83, 88, LED680(on: lit))
            at(136, 70, Label680(text: "HLT"))
            at(136, 88, LED680(on: lit && !model.run680))
            at(187, 70, Label680(text: "RUN"))
            at(187, 88, LED680(on: lit && model.run680))

            at(93, 129, Label680(text: "RESET"))
            at(81, 160, Momentary680 { model.panel680Reset() })
            at(142, 129, Label680(text: "HLT"))
            at(142, 156, Toggle680(on: !model.run680) { model.panel680SetRun(!model.run680) })
            at(148, 183, Label680(text: "RUN"))
            at(196, 129, Label680(text: "DEP"))
            at(192, 160, Momentary680 { model.panel680Deposit() })
        }
    }

    private var dataRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                let bit = 7 - i
                let x = P680.dataX[i]
                at(x, P680.dataLEDY, LED680(on: lit && model.led680Data & (1 << UInt8(bit)) != 0))
                tick(x, P680.dataLEDY + 17)
                at(x, P680.dataLabelY, Label680(text: "D\(bit)"))
                at(x, P680.dataSwitchY, Toggle680(on: model.sw680Data & (1 << UInt8(bit)) != 0) { model.toggle680Data(bit) })
            }
            bracket(512, 711, P680.dataBracketY)
            bracket(724, 915, P680.dataBracketY)
            at(934, 160, Label680(text: "DATA", size: 13))
        }
    }

    private var addressRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<16, id: \.self) { i in
                let bit = 15 - i
                let x = P680.addressX[i]
                at(x, P680.addressLEDY, LED680(on: lit && model.led680Address & (1 << UInt16(bit)) != 0))
                tick(x, P680.addressLEDY + 17)
                at(x, P680.addressLabelY, Label680(text: "A\(bit)"))
                at(x, P680.addressSwitchY, Toggle680(on: model.sw680Address & (1 << UInt16(bit)) != 0) { model.toggle680Address(bit) })
            }
            bracket(90, 276, P680.addressBracketY)
            bracket(289, 474, P680.addressBracketY)
            bracket(512, 711, P680.addressBracketY)
            bracket(724, 952, P680.addressBracketY)
            at(936, 283, Label680(text: "ADDRESS", size: 13))
        }
    }

    /// 両端が少し立ち上がった下線(写真の「⌊___⌋」)
    private func bracket(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: x1 * s, y: (y - 5) * s))
            p.addLine(to: CGPoint(x: x1 * s, y: y * s))
            p.addLine(to: CGPoint(x: x2 * s, y: y * s))
            p.addLine(to: CGPoint(x: x2 * s, y: (y - 5) * s))
        }
        .stroke(P680.label.opacity(0.9), lineWidth: 1.3 * s)
    }

    /// 左下のロゴ: 薄い灰色の「MITS」と、青い太字の「ALTAIR 680」
    private var logo: some View {
        ZStack(alignment: .topLeading) {
            Text("MITS")
                .font(.custom("Avenir Next", size: 34 * s).weight(.medium))
                .tracking(3 * s)
                .foregroundStyle(P680.logoGray)
                .fixedSize()
                .position(x: 186 * s, y: 367 * s)
            Text("ALTAIR 680")
                .font(.custom("Avenir Next", size: 38 * s).weight(.heavy))
                .tracking(2 * s)
                .foregroundStyle(P680.logoBlue)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 270 * s)
                .position(x: 388 * s, y: 367 * s)
        }
    }
}
