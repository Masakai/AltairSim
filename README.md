# Altair 8800 Simulator (Swift / macOS)

Intel 8080 搭載の Altair 8800(1975年)のシミュレータ。

## 実行

```bash
swift run AltairSim   # アプリ起動
swift test            # CPU・パネル・ローダーのテスト
```

## 構成

- `Sources/AltairCore`: 8080 CPU(全命令、クロック数つき)、64KB メモリ、2SIO 相当のシリアル(ポート 10h/11h)、センススイッチ(ポート FFh)、Intel HEX ローダー
- `Sources/AltairSim`: SwiftUI のフロントパネル(A0-A15 スイッチ、アドレス/データ LED、EXAMINE/DEPOSIT/RUN/STEP/RESET)と端末

## 使い方

- 「デモを読み込む」→ HELLO / ECHO を 0000 に配置、RUN/STOP で実行
- 手入力: アドレススイッチを設定して EXAMINE、データを設定して DEPOSIT NEXT を繰り返す
- BASIC 等は手元のイメージ(`.bin` は 0000 に配置、`.hex` はレコードのアドレスに配置)を「ファイルを読み込む」で読み込み、RESET → RUN

## ROM

`Sources/AltairSim/Resources/roms` に配布元から取得した ROM を置いています。

| ファイル | 取得元 |
|---|---|
| `8kBas_e0/e8/f0/f8.bin`(Altair BASIC 8K、E000h〜) | altairclone.com/downloads/roms/8K BASIC/ |
| `88dskrom.bin` `altmon.bin` `turnmon.bin` | github.com/tommojphillips/Altair8800/tree/master/roms |

「Altair BASIC 8K ROM で起動」で E000h に取り付けて実行します(RAM 32KB)。
BASIC ROM はシリアルをポート 00h/01h(2SIO 形式)で使うため、シミュレータは 00h/01h と 10h/11h の両方を同じ端末に接続しています。
`88dskrom.bin`(ディスクブート)は 88-DCDD 未実装のため使えません。`altmon.bin` `turnmon.bin` は未検証です。

## 速度オプション

端末の上のメニューで切り替えます。

- CPU: `2MHz(実機)`(実時間に合わせて実行し、遅れた分は取り戻す。0.1 秒を超える遅れは切り捨て)/ `最速`
- シリアル: `制限なし` / 9600 / 1200 / 300 / 110 ボー(テレタイプ、11 ビット/文字)。
  送信可ビット(ステータスの bit1)が文字の所要時間だけ下がり、BASIC などステータスを見て出力するプログラムが遅くなる

## ディスクと CP/M

- 88-DCDD フロッピーディスクコントローラ(ポート 08h-0Ah、ドライブ A〜P)を実装しています。回転待ちは時間ではなく「セクタレジスタを読むたびに 1 セクタ進む」簡易モデルです
- ディスクイメージは 77 トラック × 32 セクタ × 137 バイト(337,568 バイト)以上の .dsk です。配布されている .dsk は末尾に余白があります(CP/M 2.2 は 337,664 バイト)
- 「CP/M 2.2 で起動」: 同梱の `Resources/disks/cpm22b23-56k.dsk`(altairclone.com から取得)を `~/Library/Application Support/AltairSim/disks/` に作業用コピーとして置き、ドライブ A に装着し、88dskrom(FF00h)から起動します。RAM は 64KB。ディスクへの書き込みは作業用コピーに反映され、元のファイルは変わりません
- 「ディスク」メニューから、ドライブ A〜D に任意の .dsk を装着・取り外しできます。この場合は選んだファイルに直接書き込まれます
- 「CP/M 3 で起動」: 同梱の `cpm3_v1.0_56K_disk1.dsk` をドライブ A、`cpm3_v1.0_56k_disk2.dsk` をドライブ B に装着して起動します。作業用コピーの扱いは CP/M 2.2 と同じです
- 動作確認: CP/M 2.2b の起動、`DIR`、`PIP` によるファイルコピー(ディスク書き込み)、`MBASIC`(BASIC-80)の `PRINT 2+3`

## ディスクドライブ画面

パネルの下に 88-DCDD のドライブ A・B を描いています(Altair 8800 の下に積まれる青い筐体の写真をもとにした配色)。ドアをクリックするとディスクの装着(ファイル選択)と取り出しを切り替えます。装着中はスロットにスリーブとファイル名、アクセス中は IN USE ランプ、ヘッド位置は TRK で表示します。

CP/M 3 の動作確認: `CP/M V3.0 Loader` から `CP/M 3 BIOS v1.0 for Altair 8" Floppy` まで起動、`DIR`、`PIP` による B ドライブへの書き込み、`MBASIC`(BASIC-80 Rev. 5.21)の `PRINT 2+3`。
