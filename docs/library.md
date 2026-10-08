# 取り込みが必要な ROM・ディスクイメージ

これらのファイルは、ライセンスの都合でリポジトリにもアプリにも含めていません。配布元の条件を確認したうえで、ご自身で取得し、アプリの「設定…」から取り込んでください(手順は README の「ROM・ディスクイメージの取り込み」)。

取り込んだファイルは `~/Library/Application Support/AltairSim/library/` の下に、次の相対パスで置かれます(手で置いてもかまいません)。項目の正式な一覧とサイズは `Sources/AltairCore/AssetLibrary.swift` の `catalog` にあります。

以下の表の「ファイル」欄の `roms/…` `disks/…` などが、ライブラリ内の置き場所です。取得元の URL は 2026-10-08 時点のものです。

| ファイル | 内容 | 取得元 |
|---|---|---|
| `roms/8kBas_e0.bin` `8kBas_e8.bin` `8kBas_f0.bin` `8kBas_f8.bin` | Altair BASIC 8K ROM(E000h〜、各 2KB) | https://altairclone.com/downloads/roms/8K%20BASIC/ |
| `roms/88dskrom.bin` | ディスクブートローダ(FF00h、256B) | https://github.com/tommojphillips/Altair8800/tree/master/roms |
| `roms/altmon.bin` `roms/turnmon.bin` | Altair モニタ / ターンキーモニタ(取得のみ、未検証) | 同上 |
| `disks/cpm22b23-56k.dsk` | CP/M 2.2b(56K、337,664 バイト) | https://altairclone.com/downloads/cpm/CPM%202.2/CPM%202.2B/ |
| `disks/cpm3_v1.0_56K_disk1.dsk` `cpm3_v1.0_56k_disk2.dsk` | CP/M 3(56K 以上の RAM 用。disk1 = システム、disk2 = ユーティリティ) | https://altairclone.com/downloads/cpm/CPM%203.0/ |
| `disks/zork.dsk` `disks/zork-ReadMe.txt` | Zork(Burcon 56K CP/M 2.2 のブータブルディスク。ZORK1、ZORK2 が遊べる) | https://altairclone.com/downloads/cpm/CPM%202.2/Zork/ |
| `disks/cpm3-ReadMe.pdf` | 上記 CP/M 3 ディスクの配布元の説明 | 同上(`ReadMe.pdf`) |

ディスクイメージは、アプリの起動ボタンを押すと `~/Library/Application Support/AltairSim/disks/` に作業用コピーが作られます。書き込みはそのコピーに入り、ライブラリのファイルは変わりません。

## Altair 680b(Motorola 6800)用

調査メモは `docs/altair680-research.md`。

| ファイル | 内容 | 取得元 |
|---|---|---|
| `altair680/monitor/MON680.S19` `MON680.ASM` `MON680.LST` | 680b PROM モニタ(ACIA 版、FF00〜FFFF)のオブジェクトとソース | https://deramp.com/downloads/altair/software/altair_680/PROM%20Monitor/ |
| `altair680/monitor/SWIMON.S19` | SWI 版モニタ(オブジェクトのみ取得) | 同上 |
| `altair680/basic/paper-basic-v1.1-r3.2.s19` | Altair 680 BASIC V1.1 R3.2(紙テープ版、S レコード) | https://deramp.com/downloads/altair/software/altair_680/BASIC/ |
| `altair680/basic/cassette-basic-v1.1-r3.2.s19` | 同(カセット版) | 同上 |
| `altair680/docs/680b-operators-manual.pdf` `680b-system-monitor-manual.pdf` | 680b の Operators Manual、System Monitor Manual | https://deramp.com/downloads/mfe_archive/010-S100%20Computers%20and%20Boards/00-MITS/99-Non-S100%20Systems/Altair%20680%20family/11-Altair%20680b/680b%20Manual/ |

### 680b のディスク OS(2026-10-08 に取得済み)

| 置き場所 | 内容 | 取得元 |
|---|---|---|
| `altair680/boot/BOOT.S19`(596 バイト) | FLEX と CP/68 の起動 PROM($FC00) | https://deramp.com/downloads/altair/software/altair_680/FLEX%201.0/BOOT.S19 |
| `altair680/disks/flex3-680.dsk`(250KB) | FLEX 3.0(`FLEX3-680.DSK`) | https://deramp.com/downloads/altair/software/altair_680/FLEX%203.0/ |
| `altair680/disks/cp68-altair680.dsk`(250KB) | CP/68(`CP68 for Altair 680.DSK`) | https://deramp.com/downloads/altair/software/altair_680/CP68/ |

`boot/BOOT.ASM`(起動 PROM のソース)と、各ディスクの ReadMe(`disks/flex3-ReadMe.txt`、`cp68-ReadMe.txt`)も同じ場所から取得しました。
配布の `FLEX3-680.DSK` は、ブートローダにシステムファイルの位置が書かれていない(LINK.CMD の実行前)ので、アプリは作業用コピーにその処理を行ってから起動します。

起動には SWIMON.S19(取得済み)を使います(CP/68 は SWI を使うため、元のモニタでは動かない、と ReadMe にあります)。
