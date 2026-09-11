#!/usr/bin/env python3
"""Build a bootable (but filesystem-less) Amiga floppy image (ADF) from a
raw boot-block binary assembled from sentinel.s.

Usage: build_adf.py <boot.bin> <out.adf>
"""
import sys

ADF_SIZE = 80 * 2 * 11 * 512  # 80 cylinders, 2 heads, 11 sectors, 512B - standard DD ADF
BOOTBLOCK_SIZE = 1024  # first two 512-byte sectors


def checksum(block: bytes) -> int:
    """Amiga boot block checksum: additive carry-wraparound sum of all
    256 longwords must equal 0xFFFFFFFF. Called with the checksum field
    (bytes 4:8) already zeroed; returns the value to store there."""
    assert len(block) == BOOTBLOCK_SIZE
    total = 0
    for i in range(0, BOOTBLOCK_SIZE, 4):
        total += int.from_bytes(block[i : i + 4], "big")
        if total > 0xFFFFFFFF:
            total = (total & 0xFFFFFFFF) + 1
    return (~total) & 0xFFFFFFFF


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    boot_bin_path, out_adf_path = sys.argv[1], sys.argv[2]

    with open(boot_bin_path, "rb") as f:
        code = f.read()
    if len(code) > BOOTBLOCK_SIZE:
        print(
            f"error: boot block code is {len(code)} bytes, must fit in {BOOTBLOCK_SIZE}",
            file=sys.stderr,
        )
        return 1

    block = bytearray(BOOTBLOCK_SIZE)
    block[: len(code)] = code
    if block[0:3] != b"DOS":
        print("error: boot block is missing the 'DOS' id at offset 0", file=sys.stderr)
        return 1

    block[4:8] = b"\x00\x00\x00\x00"
    block[4:8] = checksum(bytes(block)).to_bytes(4, "big")

    image = bytearray(ADF_SIZE)
    image[:BOOTBLOCK_SIZE] = block
    with open(out_adf_path, "wb") as f:
        f.write(image)
    return 0


if __name__ == "__main__":
    sys.exit(main())
