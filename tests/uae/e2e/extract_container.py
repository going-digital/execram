#!/usr/bin/env python3
"""Extracts the inner stub+header+payload container (docs/format-spec.md
§2/§3) from a single-hunk AmigaDOS executable produced by `execram pack`,
for the FS-UAE end-to-end boot test (see ../run_e2e_test.sh).

Reads the HUNK_CODE hunk's own declared length rather than scanning for
the "ExCr" magic: an earlier version of this script did that, and it
"worked" (found the sentinel) purely by accident - the scan found the
magic bytes' *own 4-byte encoding as a cmp.l immediate inside the stub's
code* (stubs/common/runtime.i's `cmp.l #MAGIC,...`) instead of the real
header, computed a nonsensical (but Python-slice-clamped-into-harmless)
length, and only "passed" because the resulting over-long slice still
happened to end at the file's true end. Trusting the hunk's own length
field is correct by construction instead of by coincidence.

Usage: extract_container.py <packed.exe> <out.bin>
"""
import struct
import sys

HUNK_HEADER = 0x3F3


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    if struct.unpack(">I", data[0:4])[0] != HUNK_HEADER:
        print("error: not a HUNK_HEADER file", file=sys.stderr)
        return 1
    table_size = struct.unpack(">I", data[8:12])[0]
    if table_size != 1:
        print(f"error: expected exactly one hunk, found {table_size}", file=sys.stderr)
        return 1

    # HUNK_HEADER (id, lib-name-list terminator, table_size, first_hunk,
    # last_hunk, one size longword) = 24 bytes for table_size=1.
    hunk_size_longs = struct.unpack(">I", data[20:24])[0] & 0x3FFFFFFF
    hunk_data_start = 32  # + HUNK_CODE's own id+length (8 bytes)
    hunk_length_bytes = hunk_size_longs * 4
    # This includes 0-3 trailing padding bytes (the hunk format pads to a
    # longword boundary) after the real stub+header+payload - harmless,
    # since the stub never reads past what its own header fields say to.
    container = data[hunk_data_start : hunk_data_start + hunk_length_bytes]

    with open(sys.argv[2], "wb") as f:
        f.write(container)
    print(f"wrote {len(container)} bytes (hunk-declared length, may include up to 3 padding bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
