#!/usr/bin/env python3
"""Boot reserved-tail/mixed-memory regression via real AmigaDOS LoadSeg.

Requires EXECRAM_KICKSTART and optional EXECRAM_FSUAE. Uses 512K Chip +
512K Slow RAM, with no Fast expansion; no copyrighted assets are fetched.
Accepts backend names (default: store zultra salvador shrinkler lz4small).
"""
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]

def run(*args):
    subprocess.run(args, check=True)

def boot(exe, work, label):
    serial = work / (label + '.serial')
    serial.touch()
    slave_file = work / (label + '.slave')
    with slave_file.open('w') as slave:
        bridge = subprocess.Popen([sys.executable, str(ROOT / 'tests/uae/boot/pty_bridge.py'), str(serial), '100'], stdout=slave)
    emulator = None
    try:
        for _ in range(100):
            if slave_file.stat().st_size:
                break
            time.sleep(.05)
        port = slave_file.read_text().strip()
        if not port:
            raise RuntimeError('serial bridge did not start')
        with (work / (label + '.log')).open('w') as log:
            emulator = subprocess.Popen([
                os.environ.get('EXECRAM_FSUAE', '/Applications/FS-UAE.app/Contents/MacOS/fs-uae'),
                '--kickstart_file=' + os.environ['EXECRAM_KICKSTART'],
                '--floppy_drive_0=' + str(exe), '--floppy_drive_count=1',
                '--amiga_model=A500', '--chip_memory=512', '--slow_memory=512', '--fast_memory=0',
                '--serial_port=' + port, '--fullscreen=0', '--window_width=200', '--window_height=100',
            ], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                data = serial.read_bytes()
                if b'EXECRAM-MIXED-OK\r\n' in data or b'EXECRAM-MIXED-OK\n' in data:
                    print('PASS:', label, flush=True)
                    return
                if b'EXECRAM-MIXED-FAIL' in data or emulator.poll() is not None:
                    break
                time.sleep(.25)
            raise RuntimeError(f'{label}: boot failed; serial={serial.read_bytes()!r}; logs at {work}')
    finally:
        for process in (emulator, bridge):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

def main():
    if not os.environ.get('EXECRAM_KICKSTART'):
        raise SystemExit('Set EXECRAM_KICKSTART to your local licensed ROM')
    work = Path(tempfile.mkdtemp(prefix='execram-mixed-'))
    print('Artifacts:', work, flush=True)
    obj, original = work / 'program.o', work / 'original.exe'
    run(os.environ.get('EXECRAM_VASM', 'vasmm68k_mot'), '-Fhunk', '-no-opt', '-quiet', '-o', str(obj), str(ROOT / 'tests/fixtures/mixed_memory.s'))
    run(os.environ.get('EXECRAM_VLINK', 'vlink'), '-bamigahunk', '-o', str(original), str(obj))
    data = bytearray(original.read_bytes())
    struct.pack_into('>I', data, 20, 220000 // 4)
    original.write_bytes(data)
    boot(original, work, 'original')
    for backend in sys.argv[1:] or ['store', 'zultra', 'salvador', 'shrinkler', 'lz4small']:
        output = work / (backend + '.exe')
        run(str(ROOT / 'zig-out/bin/execram'), 'pack', '--backend=' + backend, str(original), str(output))
        boot(output, work, backend)

if __name__ == '__main__':
    main()
