#!/usr/bin/env python3
"""Validates and passes through an execram-packed executable
(docs/format-spec.md §2, docs/memory-lifecycle.md) for the FS-UAE
end-to-end boot test (see ../run_e2e_test.sh and friends).

Used to *extract* the inner stub+header+payload container from a
single-hunk packed file, back when ../loader.s jumped straight into
that container with no AmigaDOS environment around it at all. Now that
execram produces a real two-hunk load file (hunk 0: the trampoline,
declared at the full resident size; hunk 1: the actual stub+header+
payload container - see stubs/common/runtime.i's own header comment for
the full design), loader.s parses that structure itself, the same way a
real LoadSeg would - so there's nothing left to extract. This just
validates the shape before wasting time booting something malformed
(kept from this script's original design, when it fixed a real "found
the wrong bytes anyway" bug - see the git history around when the
single-hunk version of this script was added, or `git log --oneline
--grep="coincidence"`) and copies the file through unchanged.

Usage: extract_container.py <packed.exe> <out.bin>
"""
import struct
import sys

HUNK_CODE = 0x3E9
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
    if table_size != 2:
        print(f"error: expected exactly two hunks, found {table_size}", file=sys.stderr)
        return 1
    # Offset 28 (HUNK_HEADER + reslist + table_size + first_hunk +
    # last_hunk + two size-table longwords = 7 longwords) is hunk 0's
    # own HUNK_CODE marker.
    if struct.unpack(">I", data[28:32])[0] != HUNK_CODE:
        print("error: hunk 0 is not a HUNK_CODE hunk", file=sys.stderr)
        return 1

    with open(sys.argv[2], "wb") as f:
        f.write(data)
    print(f"wrote {len(data)} bytes (whole packed file, unchanged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
