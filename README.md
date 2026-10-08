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

## Zork

「Zork」ボタンで Burcon 56K CP/M 2.2 のディスク(`zork.dsk`)をドライブ A から起動します。`A>` で `ZORK1` または `ZORK2` と入力します。同梱のディスクには `ZORK3.COM` はありますがデータファイルがなく、`Load Game Disk` の表示で止まります。

## 8080 命令テスト

`Tests/Resources/cpu_tests/` の CP/M 用テストプログラムを、BDOS 呼び出し(0005h)だけを模擬するハーネスで実行します(`CPUExerciserTests`)。

| テスト | 結果 |
|---|---|
| `TST8080.COM` | `CPU IS OPERATIONAL` |
| `8080PRE.COM` | `8080 Preliminary tests complete` |
| `CPUTEST.COM`(SuperSoft Diagnostic II) | `CPU TESTS OK`(255,651,553 クロック = 2MHz で約 128 秒。配布元の説明は「2MHz で約 2 分」) |
| `8080EXM.COM`(全命令・フラグを CRC で照合) | 25 項目すべて `PASS`(23,803,378,391 クロック = 2MHz で約 3.3 時間分、リリースビルドで約 318 秒) |

8080EXM は時間がかかるので、環境変数を付けたときだけ実行します。

```bash
RUN_8080EXM=1 swift test -c release -Xswiftc -enable-testing --filter CPUExerciserTests/test8080EXM
```

## HLT の動作

Intel 8080 データシート(2-13〜2-14 ページ、Table 2-1)に合わせています。

- HLT を実行すると停止状態(HLTA)に入り、RUN スイッチは RUN のまま、HLTA が点灯、WAIT は消灯します。アドレス LED は HLT の次の番地、ステータスは HLTA + MEMR + WO(M1 は消灯)です
- 抜けられるのは RESET(PC = 0)と、INTE が 1 のときの割り込みだけです。STOP → RUN や SINGLE STEP では解除されません
- DI の後の HLT は RESET でしか抜けられません
- 割り込みを起こすスイッチは実機のパネルにないので、内部関数(`AltairMachine.requestInterrupt`)としてテストから使えるようにしています。HOLD は未実装です
- データ LED は、HLT 命令の値(76h)のままです。実機では M2 サイクルの途中でデータバスがフローティングになるため、パネルでの見え方は確認していません

## 削除キー

端末の削除キーは、起動するプログラムに合わせて送るコードを切り替えます(端末の設定「削除キー」で変更もできます)。

| 設定 | コード | 使い所 |
|---|---|---|
| BS(^H) | 08h | CP/M(既定)。「BS-SP-BS」で画面上の文字を消す |
| DEL(7F) | 7Fh | CP/M は削除した文字をそのままエコーする(ハードコピー端末向け)。Altair BASIC は `\9\` のように表示する |
| _(Altair BASIC) | 5Fh | Altair BASIC(「BASIC 8K」を起動すると自動で選ぶ)。BASIC は削除した上で `_` を表示する |

Mac の delete キーは SwiftUI の `.delete` と一致せず、U+007F の文字として届くため、文字で判定しています。fn + delete(前方削除)は ADM-3A の RUB OUT にあたる 7Fh を送ります。
