#!/usr/bin/env python3
"""
MC6800 機能テストプログラムの生成器。

全 197 オペコード・全アドレッシングモードを、多数の入力(レジスタ・フラグ・メモリ)で実行して、
実行後の状態(A、B、X、SP、CC、メモリ、スタック)のチェックサムを、期待値と比べる 6800 のプログラムを作る。

- プログラム本体(ハーネス)は 6800 の機械語。実機や他のエミュレータでも動かせる
- 期待値は、このファイルの参照モデル(Python、整数演算の定義で書いたもの)が作る。CPU の実装とは別の書き方
- 出力: Tests/Resources/6800/functional6800.s19(プログラム + テストデータ)と functional6800.txt(各ケースの内容と期待状態)

使い方: python3 Tools/gen6800_functional_test.py
実行: Tests/AltairCoreTests/CPU6800FunctionalTests.swift が、64KB のバスの上で走らせる。

メモリ配置
  0010-0040  ハーネスの変数(ゼロページ)
  0040-0041  ダイレクトのオペランド
  01E8-01F7  テスト対象のスタックの使用域(初期の SP は 01EF。RTS・RTI・PUL が読む値は 01F0 から)
  0240-0241  拡張・インデックスのオペランド(インデックスは X=0200、オフセット 40)
  0300       テスト対象の命令を置く場所(EXEC)
  0310       TRAMPA(JMP 命令。ジャンプ・復帰・SWI の戻り先)、0313 TRAMPB(分岐が成立したときの戻り先)
  0600-09BF  失敗したケースの記録
  0A00-      ハーネスのコード
  1000-      テストデータ(1 ケース 18 バイト)
"""
import sys, os, json

# ---------------------------------------------------------------------------
# 命令表
# ---------------------------------------------------------------------------
OPCODES = {  # オペコード: (ニーモニック, バイト数, クロック数)  出典は CPU6800OpcodeTableTests.swift と同じ
    0x01: ('nop', 1, 2), 0x06: ('tap', 1, 2), 0x07: ('tpa', 1, 2), 0x08: ('inx', 1, 4),
    0x09: ('dex', 1, 4), 0x0A: ('clv', 1, 2), 0x0B: ('sev', 1, 2), 0x0C: ('clc', 1, 2),
    0x0D: ('sec', 1, 2), 0x0E: ('cli', 1, 2), 0x0F: ('sei', 1, 2), 0x10: ('sba', 1, 2),
    0x11: ('cba', 1, 2), 0x16: ('tab', 1, 2), 0x17: ('tba', 1, 2), 0x19: ('daa', 1, 2),
    0x1B: ('aba', 1, 2), 0x20: ('bra', 2, 4), 0x22: ('bhi', 2, 4), 0x23: ('bls', 2, 4),
    0x24: ('bcc', 2, 4), 0x25: ('bcs', 2, 4), 0x26: ('bne', 2, 4), 0x27: ('beq', 2, 4),
    0x28: ('bvc', 2, 4), 0x29: ('bvs', 2, 4), 0x2A: ('bpl', 2, 4), 0x2B: ('bmi', 2, 4),
    0x2C: ('bge', 2, 4), 0x2D: ('blt', 2, 4), 0x2E: ('bgt', 2, 4), 0x2F: ('ble', 2, 4),
    0x30: ('tsx', 1, 4), 0x31: ('ins', 1, 4), 0x32: ('pula', 1, 4), 0x33: ('pulb', 1, 4),
    0x34: ('des', 1, 4), 0x35: ('txs', 1, 4), 0x36: ('psha', 1, 4), 0x37: ('pshb', 1, 4),
    0x39: ('rts', 1, 5), 0x3B: ('rti', 1, 10), 0x3E: ('wai', 1, 9), 0x3F: ('swi', 1, 12),
    0x40: ('nega', 1, 2), 0x43: ('coma', 1, 2), 0x44: ('lsra', 1, 2), 0x46: ('rora', 1, 2),
    0x47: ('asra', 1, 2), 0x48: ('asla', 1, 2), 0x49: ('rola', 1, 2), 0x4A: ('deca', 1, 2),
    0x4C: ('inca', 1, 2), 0x4D: ('tsta', 1, 2), 0x4F: ('clra', 1, 2), 0x50: ('negb', 1, 2),
    0x53: ('comb', 1, 2), 0x54: ('lsrb', 1, 2), 0x56: ('rorb', 1, 2), 0x57: ('asrb', 1, 2),
    0x58: ('aslb', 1, 2), 0x59: ('rolb', 1, 2), 0x5A: ('decb', 1, 2), 0x5C: ('incb', 1, 2),
    0x5D: ('tstb', 1, 2), 0x5F: ('clrb', 1, 2), 0x60: ('neg', 2, 7), 0x63: ('com', 2, 7),
    0x64: ('lsr', 2, 7), 0x66: ('ror', 2, 7), 0x67: ('asr', 2, 7), 0x68: ('asl', 2, 7),
    0x69: ('rol', 2, 7), 0x6A: ('dec', 2, 7), 0x6C: ('inc', 2, 7), 0x6D: ('tst', 2, 7),
    0x6E: ('jmp', 2, 4), 0x6F: ('clr', 2, 7), 0x70: ('neg', 3, 6), 0x73: ('com', 3, 6),
    0x74: ('lsr', 3, 6), 0x76: ('ror', 3, 6), 0x77: ('asr', 3, 6), 0x78: ('asl', 3, 6),
    0x79: ('rol', 3, 6), 0x7A: ('dec', 3, 6), 0x7C: ('inc', 3, 6), 0x7D: ('tst', 3, 6),
    0x7E: ('jmp', 3, 3), 0x7F: ('clr', 3, 6), 0x80: ('suba', 2, 2), 0x81: ('cmpa', 2, 2),
    0x82: ('sbca', 2, 2), 0x84: ('anda', 2, 2), 0x85: ('bita', 2, 2), 0x86: ('ldaa', 2, 2),
    0x88: ('eora', 2, 2), 0x89: ('adca', 2, 2), 0x8A: ('oraa', 2, 2), 0x8B: ('adda', 2, 2),
    0x8C: ('cpx', 3, 3), 0x8D: ('bsr', 2, 8), 0x8E: ('lds', 3, 3), 0x90: ('suba', 2, 3),
    0x91: ('cmpa', 2, 3), 0x92: ('sbca', 2, 3), 0x94: ('anda', 2, 3), 0x95: ('bita', 2, 3),
    0x96: ('ldaa', 2, 3), 0x97: ('staa', 2, 4), 0x98: ('eora', 2, 3), 0x99: ('adca', 2, 3),
    0x9A: ('oraa', 2, 3), 0x9B: ('adda', 2, 3), 0x9C: ('cpx', 2, 4), 0x9E: ('lds', 2, 4),
    0x9F: ('sts', 2, 5), 0xA0: ('suba', 2, 5), 0xA1: ('cmpa', 2, 5), 0xA2: ('sbca', 2, 5),
    0xA4: ('anda', 2, 5), 0xA5: ('bita', 2, 5), 0xA6: ('ldaa', 2, 5), 0xA7: ('staa', 2, 6),
    0xA8: ('eora', 2, 5), 0xA9: ('adca', 2, 5), 0xAA: ('oraa', 2, 5), 0xAB: ('adda', 2, 5),
    0xAC: ('cpx', 2, 6), 0xAD: ('jsr', 2, 8), 0xAE: ('lds', 2, 6), 0xAF: ('sts', 2, 7),
    0xB0: ('suba', 3, 4), 0xB1: ('cmpa', 3, 4), 0xB2: ('sbca', 3, 4), 0xB4: ('anda', 3, 4),
    0xB5: ('bita', 3, 4), 0xB6: ('ldaa', 3, 4), 0xB7: ('staa', 3, 5), 0xB8: ('eora', 3, 4),
    0xB9: ('adca', 3, 4), 0xBA: ('oraa', 3, 4), 0xBB: ('adda', 3, 4), 0xBC: ('cpx', 3, 5),
    0xBD: ('jsr', 3, 9), 0xBE: ('lds', 3, 5), 0xBF: ('sts', 3, 6), 0xC0: ('subb', 2, 2),
    0xC1: ('cmpb', 2, 2), 0xC2: ('sbcb', 2, 2), 0xC4: ('andb', 2, 2), 0xC5: ('bitb', 2, 2),
    0xC6: ('ldab', 2, 2), 0xC8: ('eorb', 2, 2), 0xC9: ('adcb', 2, 2), 0xCA: ('orab', 2, 2),
    0xCB: ('addb', 2, 2), 0xCE: ('ldx', 3, 3), 0xD0: ('subb', 2, 3), 0xD1: ('cmpb', 2, 3),
    0xD2: ('sbcb', 2, 3), 0xD4: ('andb', 2, 3), 0xD5: ('bitb', 2, 3), 0xD6: ('ldab', 2, 3),
    0xD7: ('stab', 2, 4), 0xD8: ('eorb', 2, 3), 0xD9: ('adcb', 2, 3), 0xDA: ('orab', 2, 3),
    0xDB: ('addb', 2, 3), 0xDE: ('ldx', 2, 4), 0xDF: ('stx', 2, 5), 0xE0: ('subb', 2, 5),
    0xE1: ('cmpb', 2, 5), 0xE2: ('sbcb', 2, 5), 0xE4: ('andb', 2, 5), 0xE5: ('bitb', 2, 5),
    0xE6: ('ldab', 2, 5), 0xE7: ('stab', 2, 6), 0xE8: ('eorb', 2, 5), 0xE9: ('adcb', 2, 5),
    0xEA: ('orab', 2, 5), 0xEB: ('addb', 2, 5), 0xEE: ('ldx', 2, 6), 0xEF: ('stx', 2, 7),
    0xF0: ('subb', 3, 4), 0xF1: ('cmpb', 3, 4), 0xF2: ('sbcb', 3, 4), 0xF4: ('andb', 3, 4),
    0xF5: ('bitb', 3, 4), 0xF6: ('ldab', 3, 4), 0xF7: ('stab', 3, 5), 0xF8: ('eorb', 3, 4),
    0xF9: ('adcb', 3, 4), 0xFA: ('orab', 3, 4), 0xFB: ('addb', 3, 4), 0xFE: ('ldx', 3, 5),
    0xFF: ('stx', 3, 6),
}

def mode_of(op):
    """オペコードのアドレッシングモード: inh / rel / imm / dir / idx / ext"""
    if 0x20 <= op < 0x30 or op == 0x8D:
        return 'rel'
    if op < 0x60:
        return 'inh'
    if op < 0x70:
        return 'idx'
    if op < 0x80:
        return 'ext'
    return {0x8: 'imm', 0x9: 'dir', 0xA: 'idx', 0xB: 'ext',
            0xC: 'imm', 0xD: 'dir', 0xE: 'idx', 0xF: 'ext'}[op >> 4]

# ---------------------------------------------------------------------------
# 小さなアセンブラ(ハーネスを書くための最小限。ラベルは 2 回のパスで解決する)
# ---------------------------------------------------------------------------
_BYNAME = {}
for _op, (_n, _l, _c) in OPCODES.items():
    _BYNAME.setdefault((_n, mode_of(_op)), _op)
WORD_IMM = {'cpx', 'lds', 'ldx'}


class Label:
    def __init__(self, name, part=None):
        self.name, self.part = name, part
def hi(name): return Label(name, 'hi')
def lo(name): return Label(name, 'lo')


class Asm:
    def __init__(self, org):
        self.org, self.labels, self.prev, self.items = org, {}, {}, []
        self.pc = org
        self.out = bytearray()

    def label(self, name):
        self.labels[name] = self.pc

    def _val(self, v):
        if isinstance(v, Label):
            a = self.prev.get(v.name, 0)
            return {'hi': a >> 8, 'lo': a & 0xFF, None: a}[v.part]
        if isinstance(v, str):
            return self.prev.get(v, 0)
        return v

    def emit(self, *bs):
        for b in bs:
            self.out.append(b & 0xFF)
        self.pc += len(bs)

    def data(self, *bs):
        self.emit(*bs)

    INVERSE = {'bne': 'beq', 'beq': 'bne', 'bcc': 'bcs', 'bcs': 'bcc', 'bpl': 'bmi', 'bmi': 'bpl',
               'bvc': 'bvs', 'bvs': 'bvc', 'bhi': 'bls', 'bls': 'bhi', 'bge': 'blt', 'blt': 'bge',
               'bgt': 'ble', 'ble': 'bgt'}

    def i(self, mn, mode='inh', arg=None):
        if mode == 'rel':
            target = self._val(arg)
            far = not (-128 <= target - (self.pc + 2) <= 127)
            if far:
                # 範囲外なので、BSR は JSR、BRA は JMP、条件分岐は「反転した分岐 + JMP」にする
                if mn == 'bsr':
                    return self.i('jsr', 'ext', arg)
                if mn == 'bra':
                    return self.i('jmp', 'ext', arg)
                self.i(self.INVERSE[mn], 'rel', self.pc + 5)
                return self.i('jmp', 'ext', arg)
        op = _BYNAME[(mn, mode)]
        self.emit(op)
        if mode == 'inh':
            return
        v = self._val(arg)
        if mode == 'rel':
            target = self._val(arg)
            self.emit((target - (self.pc + 1)) & 0xFF)
        elif mode == 'imm' and mn in WORD_IMM:
            self.emit(v >> 8, v & 0xFF)
        elif mode == 'ext':
            self.emit(v >> 8, v & 0xFF)
        else:
            assert 0 <= v <= 0xFF, (mn, mode, v)
            self.emit(v)


def assemble(build, org):
    a = Asm(org)
    for _ in range(12):
        b = Asm(org)
        b.prev = a.labels
        build(b)
        if b.labels == a.labels:
            return b
        a = b
    raise RuntimeError("ラベルが収束しなかった")

# ---------------------------------------------------------------------------
# メモリ配置
# ---------------------------------------------------------------------------
RECPTR, RUN, SRC, DST, CNT = 0x10, 0x12, 0x13, 0x15, 0x17
ASAVE, BSAVE, XSAVE, CCSAVE, SPSAVE, TAKEN = 0x19, 0x1A, 0x1B, 0x1D, 0x1E, 0x20
SUMHI, SUMLO, FAILCNT, FAILPTR, CASECNT, DONEFLAG = 0x22, 0x23, 0x24, 0x26, 0x28, 0x30
CELL_D, CELL_E = 0x0040, 0x0240
EXEC, TRAMPA, TRAMPB = 0x0300, 0x0310, 0x0313
FAILLIST, CODE, RECORDS = 0x0600, 0x0A00, 0x1000
HSTACK = 0x017F
RECSIZE = 18
MAX_FAILS = 32
PATTERN = [(0x91 + 0x1B * i) & 0xFF for i in range(16)]            # 01E8-01F7 の初期値
PRESET_RTS = [TRAMPA >> 8, TRAMPA & 0xFF]                            # 01F0-01F1
PRESET_RTI = [0xC0 | 0x2A, 0x66, 0x77, 0x12, 0x34, TRAMPA >> 8, TRAMPA & 0xFF]   # 01F0-01F6


def build_harness(A):
    zp = lambda n: n  # ゼロページのアドレス
    # --- 初期化 ---
    A.label('ENTRY')
    A.i('lds', 'imm', HSTACK)
    for v in (FAILCNT, FAILCNT + 1, CASECNT, CASECNT + 1, DONEFLAG):
        A.i('clr', 'ext', v)
    A.i('ldx', 'imm', FAILLIST); A.i('stx', 'dir', FAILPTR)
    A.i('ldx', 'imm', RECORDS); A.i('stx', 'dir', RECPTR)
    A.i('ldaa', 'imm', 0x7E)
    A.i('staa', 'ext', TRAMPA); A.i('staa', 'ext', TRAMPB)
    # --- 次のケース ---
    A.label('NEXT')
    A.i('ldx', 'dir', RECPTR)
    A.i('ldaa', 'idx', 0)
    A.i('beq', 'rel', 'FINISH')
    A.i('ldaa', 'imm', 1); A.i('staa', 'dir', RUN)
    # --- 1 回の実行(RUN = 1: フラグと分岐の確認、RUN = 2: レジスタ・メモリの確認)---
    A.label('RUNSTART')
    A.i('lds', 'imm', HSTACK)
    A.i('ldx', 'imm', Label('PATTERN')); A.i('stx', 'dir', SRC)
    A.i('ldx', 'imm', 0x01E8); A.i('stx', 'dir', DST)
    A.i('ldaa', 'imm', 16); A.i('staa', 'dir', CNT); A.i('bsr', 'rel', 'COPY')
    A.i('ldx', 'dir', RECPTR); A.i('ldaa', 'idx', 13); A.i('beq', 'rel', 'NOPRE')
    A.i('cmpa', 'imm', 1); A.i('bne', 'rel', 'PRE2')
    A.i('ldx', 'imm', Label('PRESET1')); A.i('stx', 'dir', SRC)
    A.i('ldx', 'imm', 0x01F0); A.i('stx', 'dir', DST)
    A.i('ldaa', 'imm', len(PRESET_RTS)); A.i('staa', 'dir', CNT); A.i('bsr', 'rel', 'COPY')
    A.i('bra', 'rel', 'NOPRE')
    A.label('PRE2')
    A.i('ldx', 'imm', Label('PRESET2')); A.i('stx', 'dir', SRC)
    A.i('ldx', 'imm', 0x01F0); A.i('stx', 'dir', DST)
    A.i('ldaa', 'imm', len(PRESET_RTI)); A.i('staa', 'dir', CNT); A.i('bsr', 'rel', 'COPY')
    A.label('NOPRE')
    A.i('ldx', 'dir', RECPTR)
    for off, dst in ((9, CELL_D), (10, CELL_D + 1)):
        A.i('ldaa', 'idx', off); A.i('staa', 'dir', dst)
    for off, dst in ((11, CELL_E), (12, CELL_E + 1)):
        A.i('ldaa', 'idx', off); A.i('staa', 'ext', dst)
    A.i('ldaa', 'idx', 0); A.i('staa', 'dir', CNT)
    A.i('inx'); A.i('stx', 'dir', SRC)
    A.i('ldx', 'imm', EXEC); A.i('stx', 'dir', DST)
    A.i('bsr', 'rel', 'COPY')
    A.i('ldx', 'dir', DST)
    A.i('ldaa', 'imm', 0x7E); A.i('staa', 'idx', 0); A.i('staa', 'idx', 3)
    A.i('ldaa', 'imm', TRAMPA >> 8); A.i('staa', 'idx', 1)
    A.i('ldaa', 'imm', TRAMPA & 0xFF); A.i('staa', 'idx', 2)
    A.i('ldaa', 'imm', TRAMPB >> 8); A.i('staa', 'idx', 4)
    A.i('ldaa', 'imm', TRAMPB & 0xFF); A.i('staa', 'idx', 5)
    A.i('ldaa', 'dir', RUN); A.i('cmpa', 'imm', 1); A.i('bne', 'rel', 'RUN2')
    A.i('ldx', 'imm', Label('S1A')); A.i('stx', 'ext', TRAMPA + 1)
    A.i('ldx', 'imm', Label('S1B')); A.i('stx', 'ext', TRAMPB + 1)
    A.i('bra', 'rel', 'FRAME')
    A.label('RUN2')
    A.i('ldx', 'imm', Label('S2')); A.i('stx', 'ext', TRAMPA + 1); A.i('stx', 'ext', TRAMPB + 1)
    A.label('FRAME')
    A.i('ldx', 'dir', RECPTR)
    for off, dst in ((8, 0x01E9), (5, 0x01EA), (4, 0x01EB), (6, 0x01EC), (7, 0x01ED)):
        A.i('ldaa', 'idx', off); A.i('staa', 'ext', dst)
    A.i('ldaa', 'imm', EXEC >> 8); A.i('staa', 'ext', 0x01EE)
    A.i('ldaa', 'imm', EXEC & 0xFF); A.i('staa', 'ext', 0x01EF)
    A.i('lds', 'imm', 0x01E8)
    A.i('rti')                       # CC・B・A・X・PC を一度に設定して EXEC へ(フラグを壊さない)
    # --- 実行後に呼ばれる受け皿 ---
    A.label('S1A')
    A.i('tpa'); A.i('staa', 'dir', CCSAVE); A.i('clr', 'ext', TAKEN); A.i('jmp', 'ext', 'DONE')
    A.label('S1B')
    A.i('tpa'); A.i('staa', 'dir', CCSAVE); A.i('ldaa', 'imm', 1); A.i('staa', 'dir', TAKEN); A.i('jmp', 'ext', 'DONE')
    A.label('S2')
    A.i('staa', 'dir', ASAVE); A.i('stab', 'dir', BSAVE); A.i('stx', 'dir', XSAVE)
    A.i('tsx'); A.i('stx', 'dir', SPSAVE)
    A.label('DONE')
    A.i('lds', 'imm', HSTACK)
    A.i('ldaa', 'dir', RUN); A.i('cmpa', 'imm', 1); A.i('bne', 'rel', 'CHECK')
    A.i('ldaa', 'imm', 2); A.i('staa', 'dir', RUN); A.i('jmp', 'ext', 'RUNSTART')
    # --- 結果のチェックサムを期待値と比べる ---
    A.label('CHECK')
    A.i('ldx', 'dir', RECPTR); A.i('ldaa', 'idx', 16); A.i('anda', 'dir', CCSAVE); A.i('staa', 'dir', CCSAVE)
    A.i('clr', 'ext', SUMHI); A.i('clr', 'ext', SUMLO)
    for start, n in ((ASAVE, 8), (CELL_D, 2), (CELL_E, 2), (0x01E8, 16)):
        A.i('ldx', 'imm', start); A.i('stx', 'dir', SRC)
        A.i('ldaa', 'imm', n); A.i('staa', 'dir', CNT); A.i('bsr', 'rel', 'SUMSEG')
    A.i('ldx', 'dir', RECPTR)
    A.i('ldaa', 'idx', 14); A.i('cmpa', 'dir', SUMHI); A.i('bne', 'rel', 'FAIL')
    A.i('ldaa', 'idx', 15); A.i('cmpa', 'dir', SUMLO); A.i('bne', 'rel', 'FAIL')
    A.label('ADVANCE')
    A.i('ldaa', 'dir', RECPTR + 1); A.i('adda', 'imm', RECSIZE); A.i('staa', 'dir', RECPTR + 1)
    A.i('ldaa', 'dir', RECPTR); A.i('adca', 'imm', 0); A.i('staa', 'dir', RECPTR)
    A.i('inc', 'ext', CASECNT + 1); A.i('bne', 'rel', 'ADV2'); A.i('inc', 'ext', CASECNT)
    A.label('ADV2')
    A.i('jmp', 'ext', 'NEXT')
    # --- 失敗の記録(先頭 32 件まで。ケースの位置と、実際の状態 28 バイト)---
    A.label('FAIL')
    A.i('ldaa', 'dir', FAILCNT); A.i('bne', 'rel', 'SKIPLOG')
    A.i('ldaa', 'dir', FAILCNT + 1); A.i('cmpa', 'imm', MAX_FAILS); A.i('bcc', 'rel', 'SKIPLOG')
    A.i('ldx', 'dir', FAILPTR)
    A.i('ldaa', 'dir', RECPTR); A.i('staa', 'idx', 0)
    A.i('ldaa', 'dir', RECPTR + 1); A.i('staa', 'idx', 1)
    A.i('inx'); A.i('inx'); A.i('stx', 'dir', DST)
    for start, n in ((ASAVE, 8), (CELL_D, 2), (CELL_E, 2), (0x01E8, 16)):
        A.i('ldx', 'imm', start); A.i('stx', 'dir', SRC)
        A.i('ldaa', 'imm', n); A.i('staa', 'dir', CNT); A.i('bsr', 'rel', 'COPY')
    A.i('ldx', 'dir', DST); A.i('stx', 'dir', FAILPTR)
    A.label('SKIPLOG')
    A.i('inc', 'ext', FAILCNT + 1); A.i('bne', 'rel', 'SK2'); A.i('inc', 'ext', FAILCNT)
    A.label('SK2')
    A.i('bra', 'rel', 'ADVANCE')
    # --- 終了 ---
    A.label('FINISH')
    A.i('ldaa', 'imm', 0xA5); A.i('staa', 'dir', DONEFLAG)
    A.label('HALT')
    A.i('bra', 'rel', 'HALT')
    # --- サブルーチン ---
    A.label('COPY')                  # SRC から DST へ CNT バイトコピー(SRC・DST は進む)
    A.i('ldx', 'dir', SRC); A.i('ldaa', 'idx', 0); A.i('inx'); A.i('stx', 'dir', SRC)
    A.i('ldx', 'dir', DST); A.i('staa', 'idx', 0); A.i('inx'); A.i('stx', 'dir', DST)
    A.i('dec', 'ext', CNT); A.i('bne', 'rel', 'COPY'); A.i('rts')
    A.label('SUMSEG')                # SRC から CNT バイトを、和(16 ビット、1 ビット左回転してから加算)に足す
    A.i('ldx', 'dir', SRC); A.i('ldaa', 'idx', 0); A.i('inx'); A.i('stx', 'dir', SRC)
    A.i('asl', 'ext', SUMLO); A.i('rol', 'ext', SUMHI); A.i('bcc', 'rel', 'SS1'); A.i('inc', 'ext', SUMLO)
    A.label('SS1')
    A.i('adda', 'dir', SUMLO); A.i('staa', 'dir', SUMLO)
    A.i('ldaa', 'dir', SUMHI); A.i('adca', 'imm', 0); A.i('staa', 'dir', SUMHI)
    A.i('dec', 'ext', CNT); A.i('bne', 'rel', 'SUMSEG'); A.i('rts')
    A.label('PATTERN'); A.data(*PATTERN)
    A.label('PRESET1'); A.data(*PRESET_RTS)
    A.label('PRESET2'); A.data(*PRESET_RTI)


# ---------------------------------------------------------------------------
# 参照モデル(Python)。命令の意味を「整数演算の定義」で書く。CPU 実装のビット演算とは別の形。
#   C(桁上がり/借り): 符号なしの結果が 0〜255 の範囲を出たか
#   V(オーバーフロー): 符号つきの結果が -128〜127 の範囲を出たか
#   H(ハーフキャリー): 下位 4 ビットだけの加算が 15 を超えたか(加算系のみ)
# ---------------------------------------------------------------------------
def s8(v): return v - 256 if v & 0x80 else v
def s16(v): return v - 65536 if v & 0x8000 else v


class State:
    def __init__(self):
        self.a = self.b = 0
        self.x = 0
        self.sp = 0x01EF            # RTI で戻した直後の SP(フレームは 01E9-01EF)
        self.h = self.i = self.n = self.z = self.v = self.c = 0
        self.mem = {}
        self.taken = 0

    @property
    def cc6(self):
        return (self.h << 5) | (self.i << 4) | (self.n << 3) | (self.z << 2) | (self.v << 1) | self.c

    def set_cc(self, v):
        self.h, self.i, self.n, self.z, self.v, self.c = [(v >> k) & 1 for k in (5, 4, 3, 2, 1, 0)]

    def rd(self, addr):
        assert addr in self.mem, f"モデル外のメモリ読み出し {addr:04X}"
        return self.mem[addr]

    def wr(self, addr, v):
        assert addr in self.mem, f"モデル外のメモリ書き込み {addr:04X}"
        self.mem[addr] = v & 0xFF

    def push(self, v):
        self.wr(self.sp, v); self.sp = (self.sp - 1) & 0xFFFF

    def pull(self):
        self.sp = (self.sp + 1) & 0xFFFF
        return self.rd(self.sp)

    def nz8(self, r):
        self.n = (r >> 7) & 1
        self.z = int(r == 0)

    def nz16(self, r):
        self.n = (r >> 15) & 1
        self.z = int(r == 0)


def add8(st, p, q, carry):
    total = p + q + carry
    r = total & 0xFF
    st.c = int(total > 0xFF)
    st.h = int((p & 0xF) + (q & 0xF) + carry > 0xF)
    sv = s8(p) + s8(q) + carry
    st.v = int(not (-128 <= sv <= 127))
    st.nz8(r)
    return r


def sub8(st, p, q, carry):
    total = p - q - carry
    r = total & 0xFF
    st.c = int(total < 0)
    sv = s8(p) - s8(q) - carry
    st.v = int(not (-128 <= sv <= 127))
    st.nz8(r)
    return r


def logic8(st, r):
    st.nz8(r)
    st.v = 0
    return r


def unary(st, kind, m):
    """単項演算(NEG COM LSR ROR ASR ASL ROL DEC INC TST CLR)。結果を返す。TST は None。"""
    if kind == 'neg':
        r = (0 - m) & 0xFF
        st.nz8(r); st.v = int(m == 0x80); st.c = int((0 - m) < 0)
    elif kind == 'com':
        r = (~m) & 0xFF
        st.nz8(r); st.v = 0; st.c = 1
    elif kind == 'lsr':
        r = m >> 1
        st.c = m & 1; st.nz8(r); st.v = st.n ^ st.c
    elif kind == 'ror':
        r = (st.c << 7) | (m >> 1)
        st.c = m & 1; st.nz8(r); st.v = st.n ^ st.c
    elif kind == 'asr':
        r = (m >> 1) | (m & 0x80)
        st.c = m & 1; st.nz8(r); st.v = st.n ^ st.c
    elif kind == 'asl':
        r = (m << 1) & 0xFF
        st.c = m >> 7; st.nz8(r); st.v = st.n ^ st.c
    elif kind == 'rol':
        r = ((m << 1) | st.c) & 0xFF
        st.c = m >> 7; st.nz8(r); st.v = st.n ^ st.c
    elif kind == 'dec':
        r = (m - 1) & 0xFF
        st.nz8(r); st.v = int(m == 0x80)
    elif kind == 'inc':
        r = (m + 1) & 0xFF
        st.nz8(r); st.v = int(m == 0x7F)
    elif kind == 'tst':
        st.nz8(m); st.v = 0; st.c = 0
        return None
    elif kind == 'clr':
        r = 0
        st.n, st.z, st.v, st.c = 0, 1, 0, 0
    else:
        raise ValueError(kind)
    return r


def daa(st):
    a = st.a
    low_bad = (a & 0xF) > 9 or st.h
    high_bad = a > 0x99 or st.c or ((a >> 4) > 9) or ((a >> 4) > 8 and (a & 0xF) > 9)
    correction = (0x06 if low_bad else 0) + (0x60 if high_bad else 0)
    st.a = (a + correction) & 0xFF
    st.nz8(st.a)
    if high_bad:
        st.c = 1


BRANCH = {  # ニーモニック → 成立条件
    'bra': lambda s: True, 'bhi': lambda s: not (s.c or s.z), 'bls': lambda s: bool(s.c or s.z),
    'bcc': lambda s: not s.c, 'bcs': lambda s: bool(s.c), 'bne': lambda s: not s.z, 'beq': lambda s: bool(s.z),
    'bvc': lambda s: not s.v, 'bvs': lambda s: bool(s.v), 'bpl': lambda s: not s.n, 'bmi': lambda s: bool(s.n),
    'bge': lambda s: s.n == s.v, 'blt': lambda s: s.n != s.v,
    'bgt': lambda s: not s.z and s.n == s.v, 'ble': lambda s: bool(s.z or s.n != s.v),
}


def execute(st, op, b1, b2):
    """1 命令を実行して状態 st を更新する。"""
    name, length, _ = OPCODES[op]
    mode = mode_of(op)

    def ea():
        if mode == 'dir': return b1
        if mode == 'ext': return (b1 << 8) | b2
        if mode == 'idx': return (st.x + b1) & 0xFFFF
        raise ValueError(mode)

    def byte_operand():
        return b1 if mode == 'imm' else st.rd(ea())

    def word_operand():
        if mode == 'imm':
            return (b1 << 8) | b2
        e = ea()
        return (st.rd(e) << 8) | st.rd((e + 1) & 0xFFFF)

    # アキュムレータ付きのニーモニック(adda, ldab, nega, ...)を分解する
    twoop = {'suba': 'sub', 'subb': 'sub', 'cmpa': 'cmp', 'cmpb': 'cmp', 'sbca': 'sbc', 'sbcb': 'sbc',
             'anda': 'and', 'andb': 'and', 'bita': 'bit', 'bitb': 'bit', 'ldaa': 'lda', 'ldab': 'lda',
             'staa': 'sta', 'stab': 'sta', 'eora': 'eor', 'eorb': 'eor', 'adca': 'adc', 'adcb': 'adc',
             'oraa': 'ora', 'orab': 'ora', 'adda': 'add', 'addb': 'add'}
    unary_acc = {'nega': 'neg', 'negb': 'neg', 'coma': 'com', 'comb': 'com', 'lsra': 'lsr', 'lsrb': 'lsr',
                 'rora': 'ror', 'rorb': 'ror', 'asra': 'asr', 'asrb': 'asr', 'asla': 'asl', 'aslb': 'asl',
                 'rola': 'rol', 'rolb': 'rol', 'deca': 'dec', 'decb': 'dec', 'inca': 'inc', 'incb': 'inc',
                 'tsta': 'tst', 'tstb': 'tst', 'clra': 'clr', 'clrb': 'clr'}

    if name in twoop:
        kind, is_a = twoop[name], name[-1] == 'a'
        r0 = st.a if is_a else st.b
        if kind == 'sta':
            logic8(st, r0)
            st.wr(ea(), r0)
            return
        m = byte_operand()
        if kind == 'sub': r = sub8(st, r0, m, 0)
        elif kind == 'cmp': sub8(st, r0, m, 0); return
        elif kind == 'sbc': r = sub8(st, r0, m, st.c)
        elif kind == 'add': r = add8(st, r0, m, 0)
        elif kind == 'adc': r = add8(st, r0, m, st.c)
        elif kind == 'and': r = logic8(st, r0 & m)
        elif kind == 'bit': logic8(st, r0 & m); return
        elif kind == 'eor': r = logic8(st, r0 ^ m)
        elif kind == 'ora': r = logic8(st, r0 | m)
        elif kind == 'lda': r = logic8(st, m)
        if is_a: st.a = r
        else: st.b = r
        return
    if name in unary_acc:
        kind, is_a = unary_acc[name], name[-1] == 'a'
        r = unary(st, kind, st.a if is_a else st.b)
        if r is not None:
            if is_a: st.a = r
            else: st.b = r
        return
    if name in ('neg', 'com', 'lsr', 'ror', 'asr', 'asl', 'rol', 'dec', 'inc', 'tst', 'clr'):
        e = ea()
        r = unary(st, name, 0 if name == 'clr' else st.rd(e))
        if r is not None:
            st.wr(e, r)
        return
    if name == 'cpx':
        m = word_operand()
        total = st.x - m
        r = total & 0xFFFF
        st.nz16(r)
        st.v = int(not (-32768 <= s16(st.x) - s16(m) <= 32767))
        return
    if name in ('ldx', 'lds'):
        m = word_operand()
        st.nz16(m); st.v = 0
        if name == 'ldx': st.x = m
        else: st.sp = m
        return
    if name in ('stx', 'sts'):
        v = st.x if name == 'stx' else st.sp
        e = ea()
        st.nz16(v); st.v = 0
        st.wr(e, v >> 8); st.wr((e + 1) & 0xFFFF, v & 0xFF)
        return
    if name in BRANCH:
        st.taken = int(BRANCH[name](st))
        return
    if name == 'jmp':
        return
    if name == 'jsr':
        ret = (EXEC + length) & 0xFFFF
        st.push(ret & 0xFF); st.push(ret >> 8)
        return
    if name == 'bsr':
        ret = (EXEC + 2) & 0xFFFF
        st.push(ret & 0xFF); st.push(ret >> 8)
        return
    if name == 'rts':
        st.pull(); st.pull()      # 戻り先は TRAMPA(プリセットが置いてある)
        return
    if name == 'rti':
        st.set_cc(st.pull() & 0x3F)
        st.b = st.pull(); st.a = st.pull()
        xh = st.pull(); xl = st.pull(); st.x = (xh << 8) | xl
        st.pull(); st.pull()
        return
    if name == 'swi':
        ret = (EXEC + 1) & 0xFFFF
        st.push(ret & 0xFF); st.push(ret >> 8)
        st.push(st.x & 0xFF); st.push(st.x >> 8)
        st.push(st.a); st.push(st.b)
        st.push(0xC0 | st.cc6)
        st.i = 1
        return
    simple = {
        'nop': lambda: None,
        'tap': lambda: st.set_cc(st.a & 0x3F),
        'tpa': lambda: setattr(st, 'a', 0xC0 | st.cc6),
        'inx': lambda: (setattr(st, 'x', (st.x + 1) & 0xFFFF), setattr(st, 'z', int(((st.x) & 0xFFFF) == 0))),
        'dex': lambda: (setattr(st, 'x', (st.x - 1) & 0xFFFF), setattr(st, 'z', int(st.x == 0))),
        'clv': lambda: setattr(st, 'v', 0), 'sev': lambda: setattr(st, 'v', 1),
        'clc': lambda: setattr(st, 'c', 0), 'sec': lambda: setattr(st, 'c', 1),
        'cli': lambda: setattr(st, 'i', 0), 'sei': lambda: setattr(st, 'i', 1),
        'ins': lambda: setattr(st, 'sp', (st.sp + 1) & 0xFFFF),
        'des': lambda: setattr(st, 'sp', (st.sp - 1) & 0xFFFF),
        'tsx': lambda: setattr(st, 'x', (st.sp + 1) & 0xFFFF),
        'txs': lambda: setattr(st, 'sp', (st.x - 1) & 0xFFFF),
    }
    if name in simple:
        simple[name]()
        return
    if name == 'sba': st.a = sub8(st, st.a, st.b, 0); return
    if name == 'cba': sub8(st, st.a, st.b, 0); return
    if name == 'aba': st.a = add8(st, st.a, st.b, 0); return
    if name == 'tab': st.b = logic8(st, st.a); return
    if name == 'tba': st.a = logic8(st, st.b); return
    if name == 'daa': daa(st); return
    if name == 'psha': st.push(st.a); return
    if name == 'pshb': st.push(st.b); return
    if name == 'pula': st.a = st.pull(); return
    if name == 'pulb': st.b = st.pull(); return
    raise NotImplementedError(name)


# ---------------------------------------------------------------------------
# テストデータ
# ---------------------------------------------------------------------------
PAIRS = [(0x00, 0x00), (0x00, 0x01), (0x01, 0xFF), (0x7F, 0x01), (0x80, 0xFF), (0x80, 0x80), (0xFF, 0x01), (0xFF, 0xFF),
         (0x0F, 0x01), (0x10, 0x0F), (0x55, 0xAA), (0xAA, 0x55), (0x7F, 0x7F), (0x80, 0x01), (0x01, 0x80), (0xF0, 0x10),
         (0x0F, 0xF1), (0x7F, 0x81), (0x81, 0x7F), (0xFF, 0x00), (0x00, 0xFF), (0x50, 0x50), (0x90, 0x90), (0xC3, 0x3C)]
CCS = [0x00, 0x01, 0x20, 0x21, 0x0A, 0x06, 0x2F, 0x30]       # H I N Z V C の組み合わせ(C が交互に 0/1)
XV = [0x0000, 0x0001, 0x00FF, 0x0100, 0x7FFF, 0x8000, 0x8001, 0xFFFF, 0x1234, 0xFF00, 0xAAAA, 0x5555]
NV = 12                                                         # 1 命令あたりの入力数

TWOOP = {'suba', 'subb', 'cmpa', 'cmpb', 'sbca', 'sbcb', 'anda', 'andb', 'bita', 'bitb', 'ldaa', 'ldab',
         'staa', 'stab', 'eora', 'eorb', 'adca', 'adcb', 'oraa', 'orab', 'adda', 'addb'}
UNARY_ACC = {'nega', 'negb', 'coma', 'comb', 'lsra', 'lsrb', 'rora', 'rorb', 'asra', 'asrb', 'asla', 'aslb',
             'rola', 'rolb', 'deca', 'decb', 'inca', 'incb', 'tsta', 'tstb', 'clra', 'clrb'}
UNARY_MEM = {'neg', 'com', 'lsr', 'ror', 'asr', 'asl', 'rol', 'dec', 'inc', 'tst', 'clr'}
WORD_OPS = {'cpx', 'ldx', 'lds', 'stx', 'sts'}


class Case:
    def __init__(self, op, b1=0, b2=0, a=0, b=0, x=0, cc=0, cells=(0, 0, 0, 0), preset=0, ccmask=0xFF):
        self.op, self.b1, self.b2, self.a, self.b, self.x = op, b1, b2, a, b, x
        self.cc, self.cells, self.preset, self.ccmask = cc & 0x3F, tuple(cells), preset, ccmask

    @property
    def length(self):
        return OPCODES[self.op][1]


def make_cases():
    cases = []
    for op in sorted(OPCODES):
        name, length, _ = OPCODES[op]
        mode = mode_of(op)
        if name == 'wai':
            continue                        # 割り込みが必要なので、このプログラムでは扱わない
        for k in range(NV):
            pair = PAIRS[(k * 7 + op) % len(PAIRS)]
            cc = CCS[(k + (op >> 3)) % len(CCS)]
            noise = (pair[1] ^ 0xA5) & 0xFF
            xa, xb = XV[(k * 5 + op) % len(XV)], XV[(k * 3 + (op >> 2)) % len(XV)]
            if name in TWOOP:
                is_a = name[-1] == 'a'
                reg, m = pair
                cells = (m, (~m) & 0xFF, m, (~m) & 0xFF)
                if name.startswith('st'):
                    cells = (noise, m, noise, m)
                args = dict(a=reg, b=noise) if is_a else dict(a=noise, b=reg)
                if mode == 'imm': c = Case(op, b1=m, cc=cc, **args)
                elif mode == 'dir': c = Case(op, b1=0x40, cc=cc, cells=cells, **args)
                elif mode == 'ext': c = Case(op, b1=0x02, b2=0x40, cc=cc, cells=cells, **args)
                else: c = Case(op, b1=0x40, x=0x0200, cc=cc, cells=cells, **args)
            elif name in UNARY_ACC:
                reg = pair[0]
                args = dict(a=reg, b=noise) if name[-1] == 'a' else dict(a=noise, b=reg)
                c = Case(op, cc=cc, **args)
            elif name in UNARY_MEM:
                m = pair[0]
                cells = (m, noise, m, noise)
                if mode == 'ext': c = Case(op, b1=0x02, b2=0x40, a=noise, b=pair[1], cc=cc, cells=cells)
                else: c = Case(op, b1=0x40, x=0x0200, a=noise, b=pair[1], cc=cc, cells=cells)
            elif name in WORD_OPS:
                m16 = xb
                cells = (m16 >> 8, m16 & 0xFF, m16 >> 8, m16 & 0xFF)
                if name in ('stx', 'sts'):
                    cells = (0x5A, 0xA5, 0x5A, 0xA5)
                pre_x = xa
                if mode == 'imm': c = Case(op, b1=m16 >> 8, b2=m16 & 0xFF, x=pre_x, cc=cc)
                elif mode == 'dir': c = Case(op, b1=0x40, x=pre_x, cc=cc, cells=cells)
                elif mode == 'ext': c = Case(op, b1=0x02, b2=0x40, x=pre_x, cc=cc, cells=cells)
                else: c = Case(op, b1=0x40, x=0x0200, cc=cc, cells=cells)
            elif name in BRANCH:
                c = Case(op, b1=0x03, a=pair[0], b=pair[1], x=xa, cc=(k % 16) | (0x20 if k % 3 == 0 else 0))
            elif name in ('jmp', 'jsr'):
                if mode == 'ext': c = Case(op, b1=TRAMPA >> 8, b2=TRAMPA & 0xFF, a=pair[0], b=pair[1], x=xa, cc=cc)
                else: c = Case(op, b1=0, a=pair[0], b=pair[1], x=TRAMPA, cc=cc)
            elif name == 'bsr':
                c = Case(op, b1=0, a=pair[0], b=pair[1], x=xa, cc=cc)
            elif name == 'daa':
                continue                    # 下で網羅的に作る
            elif name in ('rts', 'rti'):
                c = Case(op, a=pair[0], b=pair[1], x=xa, cc=cc, preset=1 if name == 'rts' else 2)
            else:  # 残りのインヘレント命令
                c = Case(op, a=pair[0], b=pair[1], x=xa if name != 'tsx' else xa, cc=cc)
            cases.append(c)
    # DAA は、上位ニブル 16 通り × 下位ニブルの種類 5 通り × (H, C) 4 通りを網羅する
    daa_op = next(op for op, v in OPCODES.items() if v[0] == 'daa')
    for hi_nib in range(16):
        for lo_nib in (0x0, 0x5, 0x9, 0xA, 0xF):
            for k, cc in enumerate((0x00, 0x01, 0x20, 0x21)):
                cases.append(Case(daa_op, a=(hi_nib << 4) | lo_nib, b=0x3C, cc=cc | (0x0A if (hi_nib + lo_nib) % 3 == 0 else 0), ccmask=0xFD))
    return cases


def initial_state(c):
    st = State()
    st.a, st.b, st.x = c.a, c.b, c.x
    st.set_cc(c.cc)
    for addr, v in zip((0x40, 0x41, 0x240, 0x241), c.cells):
        st.mem[addr] = v
    for k in range(16):
        st.mem[0x01E8 + k] = PATTERN[k]
    frame = [0xC0 | c.cc, c.b, c.a, c.x >> 8, c.x & 0xFF, EXEC >> 8, EXEC & 0xFF]
    for k, v in enumerate(frame):
        st.mem[0x01E9 + k] = v
    if c.preset == 1:
        for k, v in enumerate(PRESET_RTS): st.mem[0x01F0 + k] = v
    elif c.preset == 2:
        for k, v in enumerate(PRESET_RTI): st.mem[0x01F0 + k] = v
    return st


def post_bytes(c):
    """ケースを参照モデルで実行して、プログラムが集める 28 バイトの状態を返す。"""
    st = initial_state(c)
    execute(st, c.op, c.b1, c.b2)
    cc = (0xC0 | st.cc6) & c.ccmask
    sp1 = (st.sp + 1) & 0xFFFF
    out = [st.a, st.b, st.x >> 8, st.x & 0xFF, cc, sp1 >> 8, sp1 & 0xFF, st.taken]
    out += [st.mem[0x40], st.mem[0x41], st.mem[0x240], st.mem[0x241]]
    out += [st.mem[0x01E8 + k] for k in range(16)]
    return out


def checksum(bs):
    s = 0
    for b in bs:
        s = ((s << 1) | (s >> 15)) & 0xFFFF
        s = (s + b) & 0xFFFF
    return s


def record_bytes(c, chk):
    return [c.length, c.op, c.b1, c.b2, c.a, c.b, c.x >> 8, c.x & 0xFF, 0xC0 | c.cc,
            c.cells[0], c.cells[1], c.cells[2], c.cells[3], c.preset, chk >> 8, chk & 0xFF, c.ccmask, 0]


def s19(segments):
    hdr = [6, 0, 0, 0x4D, 0x43, 0x43]
    lines = ['S0' + ''.join(f'{b:02X}' for b in hdr) + f'{(~sum(hdr)) & 0xFF:02X}']  # ヘッダ(内容は不問)
    for addr, data in segments:
        for off in range(0, len(data), 32):
            chunk = data[off:off + 32]
            a = addr + off
            body = [len(chunk) + 3, a >> 8, a & 0xFF] + list(chunk)
            lines.append('S1' + ''.join(f'{b:02X}' for b in body) + f'{(~sum(body)) & 0xFF:02X}')
    lines.append('S9030000FC')
    return '\n'.join(lines) + '\n'


def main():
    harness = assemble(build_harness, CODE)
    assert harness.pc <= RECORDS, f"ハーネスが大きすぎる: {harness.pc:04X}"
    cases = make_cases()
    data = bytearray()
    listing = []
    for n, c in enumerate(cases):
        post = post_bytes(c)
        chk = checksum(post)
        data += bytes(record_bytes(c, chk))
        name = OPCODES[c.op][0]
        listing.append(f"{n:5d} {c.op:02X} {name:5s} {mode_of(c.op)}  b1={c.b1:02X} b2={c.b2:02X} "
                       f"A={c.a:02X} B={c.b:02X} X={c.x:04X} CC={0xC0 | c.cc:02X} cells={bytes(c.cells).hex()} "
                       f"preset={c.preset} | 期待 {bytes(post).hex()} sum={chk:04X}")
    data += bytes(RECSIZE)                # 終端(長さ 0)
    assert RECORDS + len(data) <= 0xF000, f"テストデータが大きすぎる: {len(data)} バイト"
    outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Tests', 'Resources', '6800')
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, 'functional6800.s19'), 'w') as f:
        f.write(s19([(CODE, bytes(harness.out)), (RECORDS, bytes(data))]))
    with open(os.path.join(outdir, 'functional6800.txt'), 'w') as f:
        f.write('\n'.join(listing) + '\n')
    meta = {'entry': CODE, 'halt': harness.labels['HALT'], 'failcnt': FAILCNT, 'casecnt': CASECNT,
            'done': DONEFLAG, 'faillist': FAILLIST, 'cases': len(cases), 'max_fails': MAX_FAILS,
            'labels': {k: v for k, v in harness.labels.items()}}
    with open(os.path.join(outdir, 'functional6800.json'), 'w') as f:
        json.dump(meta, f, indent=1)
    print(f"ケース {len(cases)} 件、ハーネス {len(harness.out)} バイト(終端 {harness.pc:04X})、"
          f"データ {len(data)} バイト → {outdir}")


if __name__ == '__main__':
    main()
