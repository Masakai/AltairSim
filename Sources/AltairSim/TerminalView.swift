import AltairCore
import SwiftUI

/// 端末の設定(速度・大文字変換・クリア)
struct TerminalControls: View {
    @ObservedObject var model: SimulatorModel

    var body: some View {
        HStack {
            Picker("CPU", selection: $model.cpuSpeed) {
                ForEach(SimulatorModel.CPUSpeed.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Picker("シリアル", selection: $model.baud) {
                ForEach(SimulatorModel.Baud.all) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Picker("削除キー", selection: $model.deleteKey) {
                ForEach(SimulatorModel.DeleteKey.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Toggle("小文字を大文字に変換", isOn: $model.uppercaseInput).font(.caption)
            Spacer()
            Button("端末をクリア", action: model.clearTerminal)
        }
    }
}

struct TerminalView: View {
    @ObservedObject var model: SimulatorModel
    @FocusState private var focused: Bool

    /// Mac の delete キー(後退削除)は U+007F、fn + delete(前方削除)は U+F728 の文字として届く。
    /// `.delete` との比較では一致しないので、文字で判定する。
    private enum DeleteKind { case backward, forward }
    private static func deleteKind(of key: KeyEquivalent) -> DeleteKind? {
        switch key.character {
        case "\u{7F}", "\u{08}": return .backward
        case "\u{F728}": return .forward
        default: return nil
        }
    }

    /// 押されたキーに対応する飾りキーのラベル(修飾キーも含む)
    private static func keyCapLabels(for press: KeyPress) -> [String] {
        var labels: [String] = []
        if press.modifiers.contains(.control) { labels.append("CTRL") }
        if press.modifiers.contains(.shift) { labels.append("SHIFT") }
        if Self.deleteKind(of: press.key) != nil { labels.append("RUB"); return labels }
        switch press.key {
        case .return: labels.append("RETURN")
        case .tab: labels.append("TAB")
        case .escape: labels.append("ESC")
        case .space: labels.append("SPACE")
        default:
            let c = String(press.key.character).uppercased()
            if ADM3AKeyboard.singleKeys.contains(c) { labels.append(c) }
        }
        return labels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ADM3AFrame(litKeys: model.litKeys) {
                CRTScreen(screen: model.screen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                model.flashKeys(Self.keyCapLabels(for: press))
                switch (press.key, Self.deleteKind(of: press.key)) {
                case (_, .backward?): model.typeBackspace()
                case (_, .forward?): model.typeRubout()
                case (.return, _): model.typeReturn()
                default:
                    if press.modifiers.contains(.control), let c = press.characters.unicodeScalars.first {
                        model.sendSerial(UInt8(c.value & 0x1F))
                    } else {
                        model.typeKey(press.characters)
                    }
                }
                return .handled
            }
            .onAppear { focused = true }
            .onTapGesture { focused = true }
        }
    }
}

// MARK: ADM-3A 風の筐体

private enum ADM3APalette {
    static let caseTop = Color(red: 0.83, green: 0.91, blue: 0.95)
    static let caseBottom = Color(red: 0.70, green: 0.80, blue: 0.86)
    static let bezel = Color(red: 0.55, green: 0.66, blue: 0.73)
    static let bezelDark = Color(red: 0.36, green: 0.46, blue: 0.53)
    static let screen = Color(red: 0.02, green: 0.04, blue: 0.03)
    static let phosphor = Color(red: 0.62, green: 1.0, blue: 0.68)
    static let plateInk = Color(red: 0.30, green: 0.40, blue: 0.47)
}

/// 筐体の幅に対する比率で画面を配置し、画面は 4:3 に固定する。
private struct ADM3AFrame<Content: View>: View {
    var litKeys: Set<String> = []
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let screenW = w * 0.84
            let screenH = screenW * 3 / 4
            let top = w * 0.07
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.04)
                    .fill(LinearGradient(colors: [ADM3APalette.caseTop, ADM3APalette.caseBottom], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: w * 0.04)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)

                // 画面まわりの枠(外側がやや明るく、画面側へ向けて暗くなる奥行き)
                RoundedRectangle(cornerRadius: w * 0.05)
                    .fill(LinearGradient(colors: [ADM3APalette.bezel, ADM3APalette.bezelDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: screenW + w * 0.06, height: screenH + w * 0.06)
                    .offset(y: top - w * 0.03)
                RoundedRectangle(cornerRadius: w * 0.04)
                    .fill(Color.black.opacity(0.55))
                    .frame(width: screenW + w * 0.018, height: screenH + w * 0.018)
                    .blur(radius: 2)
                    .offset(y: top - w * 0.009)

                content
                    .frame(width: screenW, height: screenH)
                    .offset(y: top)

                // キーボード(飾り)
                ADM3AKeyboard(width: w * 0.88, litKeys: litKeys)
                    .offset(y: top + screenH + w * 0.085)

                // 下部: 銘板と輝度つまみ
                HStack {
                    Text("ADM-3A")
                        .font(.system(size: w * 0.018, weight: .semibold, design: .serif))
                        .italic()
                        .foregroundStyle(ADM3APalette.plateInk)
                        .padding(.horizontal, w * 0.01).padding(.vertical, w * 0.004)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(ADM3APalette.plateInk.opacity(0.6), lineWidth: 1))
                    Spacer()
                    Circle()
                        .fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                        .frame(width: w * 0.03, height: w * 0.03)
                        .overlay(Rectangle().fill(Color.white.opacity(0.8)).frame(width: 2, height: w * 0.012).offset(y: -w * 0.006))
                }
                .padding(.horizontal, w * 0.08)
                .offset(y: top + screenH + w * 0.045)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .aspectRatio(0.885, contentMode: .fit)
    }
}

// MARK: CRT 画面(80 桁 × 24 行)

private struct CRTScreen: View {
    let screen: TerminalScreen
    // Menlo の文字幅は文字サイズの約 0.602 倍
    private static let advance: CGFloat = 0.602

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let corner = min(size.width, size.height) * 0.09
            let padX = size.width * 0.045
            let padY = size.height * 0.05
            let textW = size.width - padX * 2
            let textH = size.height - padY * 2
            let columns = CGFloat(TerminalScreen.columns)
            let rows = CGFloat(TerminalScreen.rows)
            let fontSize = textW / (columns * Self.advance)
            let cellW = textW / columns
            let rowH = textH / rows
            let cursor = screen.displayCursor

            ZStack(alignment: .topLeading) {
                ADM3APalette.screen

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<TerminalScreen.rows, id: \.self) { r in
                        Text(screen.rowString(r))
                            .font(.custom("Menlo", size: fontSize))
                            .foregroundStyle(ADM3APalette.phosphor)
                            .shadow(color: ADM3APalette.phosphor.opacity(0.6), radius: fontSize * 0.25)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: textW, height: rowH, alignment: .leading)
                    }
                }
                .frame(width: textW, height: textH, alignment: .topLeading)
                .offset(x: padX, y: padY)

                // カーソル(文字の上に半透明のブロックを重ねる。下の文字も読める)
                Rectangle()
                    .fill(ADM3APalette.phosphor.opacity(0.75))
                    .frame(width: cellW, height: rowH * 0.9)
                    .offset(x: padX + CGFloat(cursor.col) * cellW, y: padY + CGFloat(cursor.row) * rowH + rowH * 0.05)

                // 走査線
                Canvas { ctx, sz in
                    var y: CGFloat = 0
                    while y < sz.height {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: sz.width, height: 1)), with: .color(.black.opacity(0.2)))
                        y += 3
                    }
                }
                .allowsHitTesting(false)

                // 周辺減光(ブラウン管の丸み)
                RadialGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    center: .center,
                    startRadius: min(size.width, size.height) * 0.35,
                    endRadius: max(size.width, size.height) * 0.72
                )
                .allowsHitTesting(false)

                // ガラスの映り込み
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.55, y: 0.45))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(Color.black.opacity(0.6), lineWidth: 2))
        }
    }
}

/// ADM-3A 風キーボード(飾り)。キー配列は実機の並びを簡略化したもの。
private struct ADM3AKeyboard: View {
    let width: CGFloat
    var litKeys: Set<String> = []

    /// 1 文字キーのラベル一覧(キー入力との対応づけに使う)
    static let singleKeys: Set<String> = Set(rows.flatMap { $0 }.map(\.label).filter { $0.count == 1 })

    fileprivate typealias Key = (label: String, units: CGFloat)

    private static func keys(_ labels: String) -> [Key] {
        labels.map { (String($0), 1.0) }
    }

    fileprivate static let rows: [[Key]] = [
        [("ESC", 1.2)] + keys("1234567890-^") + [("RUB", 1.4)],
        [("TAB", 1.6)] + keys("QWERTYUIOP@[") + [("LF", 1.0)],
        [("CTRL", 1.9)] + keys("ASDFGHJKL;:") + [("RETURN", 1.7)],
        [("SHIFT", 2.3)] + keys("ZXCVBNM,./") + [("SHIFT", 2.3)],
        [("SPACE", 8.0)],
    ]
    private static let rowUnits: CGFloat = 14.6

    var body: some View {
        let pad = width * 0.025
        let inner = width - pad * 2
        let unit = inner / Self.rowUnits
        let gap = unit * 0.1
        let keyH = unit * 0.92
        let shelfH = CGFloat(Self.rows.count) * (keyH + gap) + pad * 1.4

        ZStack(alignment: .top) {
            // 手前に張り出した台座
            RoundedRectangle(cornerRadius: width * 0.03)
                .fill(LinearGradient(colors: [Color(red: 0.76, green: 0.85, blue: 0.90), Color(red: 0.64, green: 0.75, blue: 0.82)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: width * 0.03).stroke(Color.white.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                .frame(width: width, height: shelfH)

            VStack(spacing: gap) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: gap) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                            keyCap(key.label, key.units, unit: unit, gap: gap, height: keyH)
                        }
                    }
                    .frame(width: inner, alignment: .center)
                }
            }
            .padding(.top, pad * 0.7)
        }
        .frame(width: width, height: shelfH)
    }

    private func keyCap(_ label: String, _ units: CGFloat, unit: CGFloat, gap: CGFloat, height: CGFloat) -> some View {
        let lit = litKeys.contains(label)
        return RoundedRectangle(cornerRadius: unit * 0.14)
            .fill(LinearGradient(
                colors: lit ? [Color(red: 0.62, green: 1.0, blue: 0.68), Color(red: 0.30, green: 0.62, blue: 0.38)]
                            : [Color(white: 0.24), Color(white: 0.10)],
                startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: unit * 0.14).stroke(Color.white.opacity(lit ? 0.5 : 0.12), lineWidth: 0.5))
            .overlay(
                Text(label == "SPACE" ? "" : label)
                    .font(.system(size: unit * (label.count > 1 ? 0.26 : 0.36), weight: .medium))
                    .foregroundStyle(lit ? Color(white: 0.05) : Color(white: 0.88))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            )
            .shadow(color: lit ? Color(red: 0.62, green: 1.0, blue: 0.68).opacity(0.8) : .clear, radius: unit * 0.18)
            .offset(y: lit ? unit * 0.04 : 0)
            .animation(.easeOut(duration: 0.08), value: lit)
            .frame(width: unit * units - gap, height: height)
    }
}
