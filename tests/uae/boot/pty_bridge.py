#!/usr/bin/env python3
"""Bridge an FS-UAE emulated serial port to a log file.

FS-UAE's serial_port option needs a real pty (not a plain FIFO - that
silently produced zero bytes in testing here, likely because the ioctls
FS-UAE probes for modem-control lines behave differently against a FIFO
vs. a pty on macOS). This opens a pty pair, prints the slave device path
(point FS-UAE's serial_port at it) on the first line of stdout, then
copies everything written to it into <logfile> until <timeout> seconds
pass or it's killed.

The slave side is put into raw mode. Left in the default "cooked" mode,
the tty line discipline's ONLCR translation turns every outgoing 0x0A
our own 68k code sends into 0x0D 0x0A on the way out - invisible to a
human eye and to every earlier test here (they only grepped for a
sentinel substring, which tolerated the extra 0x0D silently), but a real
difference under an exact byte-for-byte comparison, as
run_large_e2e_test.sh does. Not a decompression or relocation bug: this
is purely a test-harness artifact of using a pty, confirmed by comparing
the "corrupted" transcript's content against the expected text with the
0x0D bytes stripped, which matched exactly.

Usage: pty_bridge.py <logfile> [timeout_seconds]
"""
import os
import pty
import select
import sys
import termios
import time


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    log_path = sys.argv[1]
    timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

    master_fd, slave_fd = pty.openpty()
    tty_attrs = termios.tcgetattr(slave_fd)
    tty_attrs[1] &= ~(termios.ONLCR | termios.OPOST)  # oflag: no output translation
    termios.tcsetattr(slave_fd, termios.TCSANOW, tty_attrs)
    print(os.ttyname(slave_fd), flush=True)

    end_time = time.time() + timeout
    with open(log_path, "wb") as logf:
        while time.time() < end_time:
            r, _, _ = select.select([master_fd], [], [], 0.2)
            if master_fd in r:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                logf.write(data)
                logf.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
