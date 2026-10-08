import AltairCore
import SwiftUI

// Altair 680 のフロントパネル(写真: 青い筐体、褐色がかった灰色のパネル、暗赤色の LED)をもとにした描画。
// 設計座標は 1000 x 430。FrontPanelView と同様に、表示幅に応じた倍率をすべての寸法に掛けて描く。
private enum P680 {
    static let width: CGFloat = 1000
    static let height: CGFloat = 430
    static let caseBlue = Color(red: 0.33, green: 0.55, blue: 0.70)
    static let caseEdge = Color(red: 0.21, green: 0.38, blue: 0.50)
    static let panel = Color(red: 0.36, green: 0.32, blue: 0.33)
    static let label = Color(red: 0.92, green: 0.90, blue: 0.86)
    static let ledOn = Color(red: 1.0, green: 0.16, blue: 0.14)
    static let ledOff = Color(red: 0.38, green: 0.07, blue: 0.10)
    static let logoBlue = Color(red: 0.55, green: 0.76, blue: 0.88)

    /// アドレススイッチ A15...A0 の列位置(4 ビットごとに間隔が広がる)
    static let addressX: [CGFloat] = [77, 130, 180, 229, 283, 335, 389, 443, 511, 565, 619, 673, 726, 779, 829, 879]
    /// データスイッチ D7...D0
    static let dataX: [CGFloat] = [513, 568, 621, 675, 727, 780, 832, 880]
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
            .frame(width: 15 * s, height: 15 * s)
            .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: s))
            .shadow(color: on ? P680.ledOn.opacity(0.9) : .clear, radius: 6 * s)
    }
}

private struct Label680: View {
    let text: String
    var size: CGFloat = 13
    @Environment(\.p680Scale) private var s
    var body: some View {
        Text(text).font(.system(size: size * s, weight: .medium)).foregroundStyle(P680.label).fixedSize()
    }
}

private struct Lever680: View {
    let offsetY: CGFloat
    @Environment(\.p680Scale) private var s
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.55)).frame(width: 16 * s, height: 16 * s)
            Circle().stroke(Color.black.opacity(0.7), lineWidth: s).frame(width: 16 * s, height: 16 * s)
            RoundedRectangle(cornerRadius: 2.5 * s)
                .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.6)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 7 * s, height: 22 * s)
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
            // 筐体と前面板
            RoundedRectangle(cornerRadius: 7 * s).fill(P680.caseBlue)
            RoundedRectangle(cornerRadius: 7 * s).stroke(P680.caseEdge, lineWidth: 3 * s)
            RoundedRectangle(cornerRadius: 3 * s).fill(P680.panel)
                .frame(width: 968 * s, height: 396 * s).position(x: 500 * s, y: 215 * s)
            Circle().fill(Color(white: 0.7)).frame(width: 11 * s, height: 11 * s).position(x: 36 * s, y: 36 * s)
            Circle().fill(Color(white: 0.7)).frame(width: 11 * s, height: 11 * s).position(x: 964 * s, y: 36 * s)
            Circle().fill(Color(white: 0.7)).frame(width: 11 * s, height: 11 * s).position(x: 36 * s, y: 396 * s)
            Circle().fill(Color(white: 0.7)).frame(width: 11 * s, height: 11 * s).position(x: 964 * s, y: 396 * s)

            statusCluster
            dataRow
            addressRow
            logo
        }
    }

    /// 左上: AC / HLT / RUN の LED と、RESET / HLT-RUN / DEP のスイッチ
    private var statusCluster: some View {
        ZStack(alignment: .topLeading) {
            at(77, 90, LED680(on: lit))
            at(77, 70, Label680(text: "AC"))
            at(128, 90, LED680(on: lit && !model.run680))
            at(128, 70, Label680(text: "HLT"))
            at(180, 90, LED680(on: lit && model.run680))
            at(180, 70, Label680(text: "RUN"))

            at(77, 132, Label680(text: "RESET"))
            at(77, 163, Momentary680 { model.panel680Reset() })
            at(128, 132, Label680(text: "HLT"))
            at(128, 163, Toggle680(on: !model.run680) { model.panel680SetRun(!model.run680) })
            at(128, 192, Label680(text: "RUN"))
            at(180, 132, Label680(text: "DEP"))
            at(180, 163, Momentary680 { model.panel680Deposit() })
        }
    }

    private var dataRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                let bit = 7 - i
                at(P680.dataX[i], 90, LED680(on: lit && model.led680Data & (1 << UInt8(bit)) != 0))
                at(P680.dataX[i], 122, Label680(text: "D\(bit)"))
                at(P680.dataX[i], 160, Toggle680(on: model.sw680Data & (1 << UInt8(bit)) != 0) { model.toggle680Data(bit) })
            }
            // 4 ビットごとの括弧線
            bracket(P680.dataX[0] - 28, P680.dataX[3] + 28, 190)
            bracket(P680.dataX[4] - 28, P680.dataX[7] + 28, 190)
            at(935, 187, Label680(text: "DATA", size: 12))
        }
    }

    private var addressRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<16, id: \.self) { i in
                let bit = 15 - i
                at(P680.addressX[i], 225, LED680(on: lit && model.led680Address & (1 << UInt16(bit)) != 0))
                at(P680.addressX[i], 258, Label680(text: "A\(bit)"))
                at(P680.addressX[i], 292, Toggle680(on: model.sw680Address & (1 << UInt16(bit)) != 0) { model.toggle680Address(bit) })
            }
            ForEach(0..<4, id: \.self) { g in
                bracket(P680.addressX[g * 4] - 28, P680.addressX[g * 4 + 3] + 28, 322)
            }
            at(922, 322, Label680(text: "ADDRESS", size: 12))
        }
    }

    private func bracket(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: x1 * s, y: (y - 6) * s))
            p.addLine(to: CGPoint(x: x1 * s, y: y * s))
            p.addLine(to: CGPoint(x: x2 * s, y: y * s))
            p.addLine(to: CGPoint(x: x2 * s, y: (y - 6) * s))
        }
        .stroke(P680.label.opacity(0.85), lineWidth: 1.2 * s)
    }

    private var logo: some View {
        ZStack(alignment: .topLeading) {
            Text("MITS")
                .font(.system(size: 36 * s, weight: .bold, design: .rounded))
                .foregroundStyle(P680.label.opacity(0.35))
                .overlay(Text("MITS").font(.system(size: 36 * s, weight: .bold, design: .rounded)).foregroundStyle(P680.label.opacity(0.55)).mask(Text("MITS").font(.system(size: 36 * s, weight: .bold, design: .rounded))))
                .fixedSize()
                .position(x: 140 * s, y: 380 * s)
            Text("ALTAIR 680")
                .font(.system(size: 42 * s, weight: .heavy, design: .rounded))
                .foregroundStyle(P680.logoBlue)
                .fixedSize()
                .position(x: 395 * s, y: 380 * s)
        }
    }
}
