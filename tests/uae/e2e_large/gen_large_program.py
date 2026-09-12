#!/usr/bin/env python3
"""Generates a larger, more realistic test program for the M1-M3
backends' FS-UAE end-to-end test than tests/uae/e2e/program.s's tiny
260-byte one: several KB of real English prose (compressible, but not
degenerately so - a fairer ratio test than tiny/synthetic data), a
20-entry pointer table (20 self-hunk relocations, stress-testing the
reloc stream at a density none of the smaller fixtures reach) plus two
cross-hunk relocations (the table and sentinel addresses are loaded as
absolute longs, not PC-relative), and a BSS segment to size and clear.

Writes two files from the same in-script text, so they can never drift
apart:
  - <out_s>: the assembled test program's source.
  - <out_expected>: the exact bytes it should write to the serial port
    if decompression, relocation, and execution all go correctly -
    every line of prose, in order, each newline-terminated, followed by
    the final sentinel line.

Usage: gen_large_program.py <out.s> <out_expected.txt>
"""
import sys

SENTINEL = "EXECRAM-LARGE-OK"

# Original prose, not copied from anywhere - safe to embed freely, and
# realistic English-text entropy for a fair compression ratio test. No
# apostrophes or quote characters: keeps vasm string-literal escaping
# out of the way entirely.
PARAGRAPHS = [
    "execram is an executable compressor for Amiga programs, built in the spirit of Shrinkler but designed from the start around a pluggable set of compression backends rather than one fixed algorithm.",
    "A packed executable is a single AmigaDOS hunk containing a small depacker stub, a fixed header, and a compressed payload, laid out so the stub can locate its own header through nothing more than a program counter relative reference to a label placed after its own code.",
    "The container format keeps every backend free of any knowledge about hunks, relocations, or the BSS segment. A backend just turns some number of compressed bytes back into the exact number of decompressed bytes the header promised, nothing more.",
    "Relocation is handled once, by execram itself, not by any individual backend. Every relocation site has its target hunk offset folded into the stored value at flatten time, so the runtime stub only ever needs to add one number: the final load address.",
    "The bulk segment is never compressed at all. It is pure zeros by definition, and the runtime stub asks the operating system for a cleared block of memory instead, which is both faster and smaller than shipping a run of zero bytes through any compressor.",
    "Three backends exist today. The store backend performs no compression whatsoever and exists to prove the runtime algorithm end to end before any real compressor was ready to test against it.",
    "The inflate backend adapts a public domain DEFLATE decompressor originally written for the Amiga by Keir Fraser, paired with a host side compressor taken directly from the Zig standard library, needing no vendored C code at all on that side.",
    "The zx0 backend pairs a vendored copy of an optimal parsing compressor with a tiny sixty eight thousand series depacker only a little over one hundred bytes long, one of the smallest useful decompressors available for the platform.",
    "Every backend is checked two different ways before it is considered done. First at the byte level, by hand computing the expected header fields and relocated values and comparing them against what the packer actually produced.",
    "Second, and just as importantly, by actually booting the packed program under a real emulated Amiga against a real Kickstart read only memory image, and confirming that what comes back over the emulated serial port is exactly what was expected.",
    "That second check has caught real defects that the first one could never have found, because it is the only one of the two that actually executes the sixty eight thousand series code the stub is made of, rather than merely inspecting the bytes it compiles to.",
    "One such defect involved a label meant to mark the end of the assembled stub, which had been placed inside a file that gets included before each backend supplies its own decompression routine, so it pointed at the start of that routine instead of the true end of the stub.",
    "Another involved an assembler limitation on the length of numeric labels used inside a macro, discovered only once a real decompression routine using that pattern was assembled and it failed to produce working code.",
    "A third involved a disk read request whose length was not rounded up to a whole number of five hundred and twelve byte sectors, which a real disk controller rejects outright even though nothing about the request looks wrong by inspection alone.",
    "A fourth involved a vendored compressor that printed a small progress indicator directly to the standard output stream, which happened to be the exact same channel a certain build tool uses to hold a conversation with the very test process that was trying to exercise it.",
    "None of these four defects would have been caught by reading the source code carefully, because none of them were wrong in any way that inspection reveals. Each one only became visible once real code actually ran on a real target and something real went wrong.",
    "This particular test program exists to push that same kind of verification a little further than the smaller test programs before it managed to, with several kilobytes of real text content instead of a single short sentinel line, and twenty two separate relocated pointers instead of only two or three.",
    "If every line above arrives over the serial port in the right order and without a single byte out of place, the packed program correctly allocated memory, correctly decompressed its payload, correctly patched every one of its relocations, and correctly jumped into the result.",
    "If even one byte is wrong anywhere in this transcript, something in that chain broke, and the exact position of the first difference tells you a great deal about where to go looking for the mistake.",
    "That is the whole point of testing this way. Not merely to observe that a program appears to have run to completion, but to demand that a large, specific, independently known piece of evidence come back byte for byte correct before believing anything at all worked.",
]


def render_asm(lines: list[str]) -> str:
    src = []
    src.append("; Larger end-to-end test program, generated by gen_large_program.py -")
    src.append("; do not edit by hand, edit that script instead and regenerate.")
    src.append(";")
    src.append("; Several KB of real prose (compressible but not degenerately so) plus")
    src.append("; a 20-entry pointer table, exercising the reloc stream at a density")
    src.append("; none of the smaller e2e fixtures reach. See run_large_e2e_test.sh.")
    src.append("")
    src.append("\tsection\tCODE,code")
    src.append("start:")
    src.append("\tmove.w\t#$7fff,$dff09a\t; INTENA: quiet down interrupts")
    src.append("\tmove.w\t#$7fff,$dff09c\t; INTREQ: clear pending")
    src.append("\tmove.w\t#368,$dff032\t; SERPER: ~9600 baud, PAL")
    src.append("")
    src.append("\tmove.l\t#line_table,a2\t; absolute (not PC-relative): a CODE->DATA reloc")
    src.append(f"\tmoveq\t#{len(lines) - 1},d7")
    src.append(".next_line:")
    src.append("\tmove.l\t(a2)+,a0")
    src.append("\tbsr.w\tsendmsg")
    src.append("\tdbf\td7,.next_line")
    src.append("")
    src.append("\tmove.l\t#sentinel,a0\t; also absolute: a second CODE->DATA reloc")
    src.append("\tbsr.w\tsendmsg")
    src.append(".hang:")
    src.append("\tbra.s\t.hang")
    src.append("")
    src.append("; Sends the null-terminated string at A0 over the serial port.")
    src.append("sendmsg:")
    src.append(".next:")
    src.append("\tmove.b\t(a0)+,d0")
    src.append("\tbeq.s\t.done")
    src.append("\tbsr.s\tsendchar")
    src.append("\tbra.s\t.next")
    src.append(".done:")
    src.append("\trts")
    src.append("")
    src.append("sendchar:")
    src.append("\tor.w\t#$100,d0")
    src.append("\tmove.w\td0,$dff030")
    src.append("\tmove.l\t#3000,d1")
    src.append(".delay:")
    src.append("\tsubq.l\t#1,d1")
    src.append("\tbne.s\t.delay")
    src.append("\trts")
    src.append("")
    src.append("\tsection\tDATA,data")
    src.append("line_table:")
    for i in range(len(lines)):
        src.append(f"\tdc.l\tline{i:02d}")
    src.append("")
    for i, line in enumerate(lines):
        src.append(f"line{i:02d}:")
        src.append(f"\tdc.b\t'{line}',10,0")
        src.append("\teven")
    src.append("sentinel:")
    src.append(f"\tdc.b\t'{SENTINEL}',10,0")
    src.append("\teven")
    src.append("")
    src.append("\tsection\tBSS,bss")
    src.append("; unused by this program directly, but gives the packed output a real")
    src.append("; BSS segment to size and clear, like most real Amiga executables have.")
    src.append("scratch_buffer:")
    src.append("\tds.b\t2048")
    src.append("")
    return "\n".join(src) + "\n"


def render_expected(lines: list[str]) -> bytes:
    out = bytearray()
    for line in lines:
        out += (line + "\n").encode("ascii")
    out += (SENTINEL + "\n").encode("ascii")
    return bytes(out)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    out_s, out_expected = sys.argv[1], sys.argv[2]

    for line in PARAGRAPHS:
        assert "'" not in line, f"no apostrophes/quotes allowed (vasm string escaping): {line!r}"
        assert line.isascii()

    with open(out_s, "w") as f:
        f.write(render_asm(PARAGRAPHS))
    with open(out_expected, "wb") as f:
        f.write(render_expected(PARAGRAPHS))

    total_text = sum(len(p) + 1 for p in PARAGRAPHS) + len(SENTINEL) + 1
    print(f"wrote {out_s} and {out_expected} ({len(PARAGRAPHS)} lines, {total_text} bytes of text)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
