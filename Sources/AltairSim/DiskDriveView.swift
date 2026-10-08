import SwiftUI

// MITS 88-DCDD ディスクドライブ(写真: Altair 8800 の下に積まれた青い筐体、灰色の前面板、クリーム色のドアと黒いスロット)をもとにした描画。
// 設計座標は 1000 x 250。1 筐体にドライブ 2 台で、筐体を 2 段積んで A〜D にする。FrontPanelView と同様に、表示幅に応じた倍率をすべての寸法に掛けて描く。
private enum Palette {
    static let frame = Color(red: 0.16, green: 0.44, blue: 0.66)
    static let frameDark = Color(red: 0.09, green: 0.28, blue: 0.45)
    static let plate = Color(red: 0.19, green: 0.20, blue: 0.22)
    static let plateEdge = Color(red: 0.32, green: 0.34, blue: 0.37)
    static let door = Color(red: 0.93, green: 0.91, blue: 0.80)
    static let doorShade = Color(red: 0.78, green: 0.75, blue: 0.62)
    static let label = Color(red: 0.90, green: 0.90, blue: 0.82)
    static let ledOn = Color(red: 1.0, green: 0.22, blue: 0.16)
    static let ledOff = Color(red: 0.33, green: 0.06, blue: 0.06)
}

private struct ScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    fileprivate var driveScale: CGFloat {
        get { self[ScaleKey.self] }
        set { self[ScaleKey.self] = newValue }
    }
}

/// 2 台入りのドライブ筐体 1 つ。first は左のドライブ番号(0 なら A・B、2 なら C・D)。
struct DiskDriveView: View {
    @ObservedObject var model: SimulatorModel
    let first: Int
    private static let width: CGFloat = 1000
    private static let height: CGFloat = 250

    var body: some View {
        GeometryReader { geo in
            Unit(model: model, first: first)
                .environment(\.driveScale, geo.size.width / Self.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(Self.width / Self.height, contentMode: .fit)
    }
}

private struct Unit: View {
    @ObservedObject var model: SimulatorModel
    let first: Int
    @Environment(\.driveScale) private var s

    private func at<V: View>(_ x: CGFloat, _ y: CGFloat, _ view: V) -> some View {
        view.position(x: x * s, y: y * s)
    }

    private func text(_ t: String, _ size: CGFloat, _ color: Color = Palette.label, weight: Font.Weight = .regular) -> some View {
        Text(t).font(.system(size: size * s, weight: weight)).foregroundStyle(color).fixedSize()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8 * s).fill(Palette.frame)
            RoundedRectangle(cornerRadius: 8 * s).stroke(Palette.frameDark, lineWidth: 3 * s)
            RoundedRectangle(cornerRadius: 3 * s)
                .fill(LinearGradient(colors: [Palette.plateEdge, Palette.plate], startPoint: .top, endPoint: .bottom))
                .frame(width: 972 * s, height: 218 * s)
                .position(x: 500 * s, y: 125 * s)

            // 左側: 電源トグル(飾り)と銘板
            at(70, 82, PowerToggle())
            at(70, 42, text("POWER", 9))
            at(122, 70, text("ON", 8))
            at(122, 96, text("OFF", 8))
            at(112, 190, text(model.computer == .altair680b ? "pertec" : "altair disk", 20, Palette.label, weight: .heavy).italic())
            at(112, 214, text(model.computer == .altair680b ? "FD3712 / 68-UIO" : "88-DCDD", 9))

            ForEach(0..<2, id: \.self) { k in
                Bay(model: model, index: first + k, width: 380)
                    .frame(width: 380 * s, height: 190 * s)
                    .position(x: (k == 0 ? 400 : 780) * s, y: 125 * s)
            }
        }
    }
}

private struct PowerToggle: View {
    @Environment(\.driveScale) private var s
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.35)).frame(width: 16 * s, height: 16 * s)
            Circle().stroke(Color.black, lineWidth: s).frame(width: 16 * s, height: 16 * s)
            RoundedRectangle(cornerRadius: 2 * s)
                .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.55)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 6 * s, height: 20 * s)
                .offset(y: -10 * s)
        }
    }
}

/// ドライブ 1 台分(クリーム色のドア、黒いスロット、使用中ランプ、トラック表示)。高さ 190、幅は width。
private struct Bay: View {
    @ObservedObject var model: SimulatorModel
    let index: Int
    let width: CGFloat
    @Environment(\.driveScale) private var s

    private var info: SimulatorModel.DriveInfo { model.drives[index] }
    private var driveName: String { String(UnicodeScalar(UInt8(65 + index))) }

    var body: some View {
        Button {
            if info.loaded { model.ejectDisk(drive: index) } else { model.mountDisk(drive: index) }
        } label: {
            door
        }
        .buttonStyle(.plain)
        .frame(width: width * s, height: 190 * s)
        .contentShape(Rectangle())
        .help(info.loaded ? "クリックでディスクを取り出す" : "クリックでディスクイメージを装着")
        .accessibilityLabel("ドライブ \(driveName)")
        .accessibilityValue(info.loaded ? info.name : "ディスクなし")
    }

    private var door: some View {
        ZStack {
            // ドア本体(面取りと影)
            RoundedRectangle(cornerRadius: 7 * s)
                .fill(LinearGradient(colors: [Palette.door, Palette.doorShade], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 7 * s).stroke(Color.black.opacity(0.35), lineWidth: 1.5 * s))
                .shadow(color: .black.opacity(0.5), radius: 3 * s, y: 2 * s)
                .frame(width: (width - 15) * s, height: 118 * s)
                .offset(y: 14 * s)
            RoundedRectangle(cornerRadius: 5 * s)
                .stroke(Color.white.opacity(0.6), lineWidth: 1.5 * s)
                .frame(width: (width - 25) * s, height: 108 * s)
                .offset(y: 14 * s)

            // スロット
            RoundedRectangle(cornerRadius: 3 * s)
                .fill(LinearGradient(colors: [Color(white: 0.02), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                .frame(width: (width - 45) * s, height: 26 * s)
                .overlay(RoundedRectangle(cornerRadius: 3 * s).stroke(Color.black, lineWidth: 2 * s))
                .offset(y: 20 * s)

            // 挿入中のディスク(スリーブが少しはみ出す)
            if info.loaded {
                ZStack {
                    RoundedRectangle(cornerRadius: 2 * s)
                        .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                        .frame(width: (width - 63) * s, height: 14 * s)
                    Rectangle().fill(Palette.label.opacity(0.9)).frame(width: 40 * s, height: 6 * s).offset(x: -(width - 63) * 0.28 * s)
                }
                .offset(y: 20 * s)
            }

            // ドアの取っ手
            RoundedRectangle(cornerRadius: 2 * s)
                .fill(Palette.doorShade)
                .frame(width: 80 * s, height: 8 * s)
                .offset(y: -14 * s)

            // ドライブ名、使用中ランプ、トラック表示
            Text(driveName).font(.system(size: 16 * s, weight: .bold)).foregroundStyle(Palette.label)
                .position(x: 18 * s, y: 12 * s)
            Circle()
                .fill(info.busy ? Palette.ledOn : Palette.ledOff)
                .frame(width: 12 * s, height: 12 * s)
                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: s))
                .shadow(color: info.busy ? Palette.ledOn.opacity(0.9) : .clear, radius: 5 * s)
                .position(x: 42 * s, y: 12 * s)
            Text("IN USE").font(.system(size: 7 * s)).foregroundStyle(Palette.label)
                .position(x: 72 * s, y: 12 * s)
            Text(info.loaded ? String(format: "TRK %02d", info.track) : "NO DISK")
                .font(.system(size: 9 * s, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.25))
                .position(x: (width - 45) * s, y: 12 * s)

            // ファイル名
            Text(info.loaded ? info.name : "クリックで装着")
                .font(.system(size: 9 * s))
                .foregroundStyle(Color(white: 0.30))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: (width - 40) * s)
                .offset(y: 62 * s)
        }
        .frame(width: width * s, height: 190 * s)
    }
}
