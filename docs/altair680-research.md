# Altair 680(680b)調査メモ(2026-10-08)

Altair 680(Motorola 6800 搭載)をシミュレータに加えるための調査結果。

## 確認できたこと

出典はすべて 680b 向けの文書で、初代の 680 と同一かどうかは未確認。

- 製品名は Altair 680。1975 年 11 月発表、出荷は 1976 年 5 月(Wikipedia)
- 680b のフロントパネル(Operators Manual、MITS 1976)
  - 電源表示の LED「AC」、アドレス LED A0〜A15、データ LED D0〜D7(16 進 4 桁と 2 桁で読めるように並ぶ)
  - アドレススイッチ、データスイッチ、DEPOSIT、RESET、RUN-HALT、POWER
  - EXAMINE スイッチはない。HALT 中は、アドレススイッチが示す番地を常に読み続け、LED にその番地と中身を表示する。DEPOSIT でデータスイッチの値を書き込む
  - スイッチが下なら 0(LED 消灯)、上なら 1(LED 点灯)
  - 手順: RUN-HALT を HALT → 電源 ON → RESET → アドレス設定 → データ設定 → DEPOSIT を繰り返す。「ターミナルなし」ビットを設定していると、RUN にしたとき PC は 0 から始まる
- 標準の RAM は 1KB。開始番地はジャンパで 0000、2000、4000、5000、6000、8000 などに設定
- シリアル: 6850 ACIA。ボーレートは 110〜9600 をジャンパで選択。20mA カレントループか RS-232。ストップビットは 1 か 2
- PROM モニタ(ACIA 版): FF00〜FFFF の 256 バイト
  - ACIA: コントロール/ステータスが F000、データが F001
  - 設定ストラップ(端末の有無、ストップビット)は F002 を読む(OCR で「F#s2」と読めた箇所。要確認)
  - モニタの作業領域は 00F2〜00FF(ECHO は 00F3、SAVSTK は 00F6〜00F7)。スタックは RESET で 00F1 付近に初期化
  - ベクタ: RESET は FFFE。NMI、SWI、IRQ も FFF8〜FFFF に並ぶ
  - プロンプトは「.」。コマンド: M(メモリ表示と書き込み)、N(次番地)、J(実行)、L(S レコードの読み込み)、P(ブレークポイントから再開)ほか
- BASIC は S レコード(S19)で、モニタの L コマンドから読み込む。起動は `J 0000`(joewing.net の記述)

## 入手先(2026-10-08 に取得済み。配置は `Sources/AltairSim/Resources/altair680/`)

- https://deramp.com/downloads/altair/software/altair_680/PROM%20Monitor/
  - `MON680.S19`(632 バイト)、`MON680.ASM`、`MON680.LST`、`SWIMON.S19`、`SWIMON.ASM`、`SWIMON.LST`、`680b Monitor.pdf`
- https://deramp.com/downloads/altair/software/altair_680/BASIC/
  - `Paper BASIC V1.1 R3.2.S19`(18KB)、`Paper BASIC V1.1 R3.2.BIN`(6.7KB)、`Cassette BASIC V1.1 R3.2.S19`(19KB)、`Cassette BASIC V1.1 R3.2.BIN`(7.0KB)、`680b BASIC.pdf`
- マニュアル: https://deramp.com/downloads/mfe_archive/010-S100%20Computers%20and%20Boards/00-MITS/99-Non-S100%20Systems/Altair%20680%20family/11-Altair%20680b/680b%20Manual/
  - Operators Manual、System Monitor Manual、Schematic、Theory of Operation、Programming Manual など

## 確認できていないこと

- 初代 680 と 680b の違い(パネル、メモリマップ)
- 680 のパネルの外観(配色、スイッチの並び、ロゴ)。写真が必要
- BASIC のメモリ要件、起動の細部、ACIA の初期化値
- 6800 の CPU 単体テストプログラム(8080 の 8080EXM に当たるもの)。検索では見つからなかった
- ライセンス(BASIC、モニタの再配布)

## 取得後に分かったこと(MON680.ASM より)

- ACIA: `ACIACS` = $F000、`ACIADA` = $F001、ストラップ `STRAPS` = $F002
- 割り込みベクタは RAM 経由: `MIVEC` = $0100(IRQ)、`NMIVEC` = $0104(NMI)
- モニタの変数は $00F1 から(スタック底、BRKADR、ECHO、EXTFLG、BUFULL、SAVSTK、TEMP、BYTECT、XHI、XLOW…)
- BASIC の S レコード(紙テープ版)は 429 行、アドレス 0000 から読み込む。最終レコードで $00F3(ECHO)を 0 に戻す

## クロック(2026-10-08 追記、一次資料で確認)

680b Theory of Operation(deramp.com の `Altair 680b 99- theory of operation.pdf`、OCR で確認)の記述:

- 「The system clock is a 500 KHz asymmetrical, two phase, non-overlapping clock」
- 2MHz の水晶で astable multi-vibrator が発振し、J-K フリップフロップ 2 個(ジョンソンカウンタ)と NOR 4 個で Phase 1 / Phase 2 を作る。「With a divide factor of four, this circuit produces a clock frequency of 500 KHz」
- Phase 1 は 600ns High / 1.4µs Low、Phase 2 は 1µs High / 1µs Low
- データ転送は Phase 2 の間に行い、メモリと ACIA の有効化にも Phase 2 を使う
- ボーレート発生器(Fairchild のプログラマブル・ビットレートジェネレータ)は別の 2.4576MHz の水晶。出力は設定ボーレートの 16 倍(9600 ボーなら 153.6kHz)

## 6800 の CPU テストについて(2026-10-08)

- Michael Steil 氏の「m6800_functional_test」は、GitHub の API(コード検索、リポジトリ検索、mist64 のリポジトリ一覧)と Web 検索では見つからなかった。
- 代わりに https://github.com/JimInCA/motorola-6800-assembler(6800 ファミリ用のクロスアセンブラ。CPU テストではない)を、命令表の照合に使った。
  - `src/table0.c` と `src/do0.c` から、全オペコード(有効 197 個)の命令の長さとクロック数を展開し、`CPU6800OpcodeTableTests` で CPU と突き合わせた。
  - 結果: 長さとクロック数は全部一致。未定義のはずの 7 つのオペコード(0x21、0x93、0xA3、0xB3、0xD3、0xE3、0xF3)を有効扱いにしていた不具合を見つけて直した(0x93 などは STS/STX として実行されメモリを書き換えていた)。
  - このテストで確認できるのは、命令の長さ・クロック数・有効か未定義かだけ。フラグや演算結果の照合ではない。
  - リポジトリにライセンス表示がないため、コードは取り込んでいない(表から展開した事実だけをテストに置いた)。
