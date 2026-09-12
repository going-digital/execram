#!/usr/bin/env python3
"""Builds a bootable ADF for run_e2e_test.sh: the 1024-byte boot block is
loader.s (assembled separately with -DPAYLOAD_LEN=<container length>),
and the container itself (an execram-packed program's inner
stub+header+payload, extracted by extract_container.py) follows
immediately at byte offset 1024 - exactly where the loader's own
IO_OFFSET points when it reads it back in.

Usage: build_disk.py <loader.bin> <container.bin> <out.adf>
"""
import sys

ADF_SIZE = 80 * 2 * 11 * 512  # 80 cylinders, 2 heads, 11 sectors, 512B - standard DD ADF
BOOTBLOCK_SIZE = 1024


def checksum(block: bytes) -> int:
    """Same algorithm as boot/build_adf.py - see that file's comment for
    the full explanation. Duplicated rather than imported to keep each
    test script standalone; if this drifts out of sync, both are simple
    enough to compare by eye."""
    assert len(block) == BOOTBLOCK_SIZE
    total = 0
    for i in range(0, BOOTBLOCK_SIZE, 4):
        total += int.from_bytes(block[i : i + 4], "big")
        if total > 0xFFFFFFFF:
            total = (total & 0xFFFFFFFF) + 1
    return (~total) & 0xFFFFFFFF


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    loader_path, container_path, out_path = sys.argv[1:4]

    with open(loader_path, "rb") as f:
        loader = f.read()
    with open(container_path, "rb") as f:
        container = f.read()

    if len(loader) > BOOTBLOCK_SIZE:
        print(f"error: loader is {len(loader)} bytes, must fit in {BOOTBLOCK_SIZE}", file=sys.stderr)
        return 1
    if BOOTBLOCK_SIZE + len(container) > ADF_SIZE:
        print("error: container too large for an 880K ADF", file=sys.stderr)
        return 1

    block = bytearray(BOOTBLOCK_SIZE)
    block[: len(loader)] = loader
    if block[0:3] != b"DOS":
        print("error: loader is missing the 'DOS' id at offset 0", file=sys.stderr)
        return 1
    block[4:8] = b"\x00\x00\x00\x00"
    block[4:8] = checksum(bytes(block)).to_bytes(4, "big")

    image = bytearray(ADF_SIZE)
    image[:BOOTBLOCK_SIZE] = block
    image[BOOTBLOCK_SIZE : BOOTBLOCK_SIZE + len(container)] = container

    with open(out_path, "wb") as f:
        f.write(image)
    return 0


if __name__ == "__main__":
    sys.exit(main())
