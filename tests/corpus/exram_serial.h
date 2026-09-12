/* execram test instrumentation - minimal Amiga serial output.
 *
 * Not part of execram itself - a small, portable snippet for
 * instrumenting a real test-corpus program (like hexagon.exe) so
 * execram's existing FS-UAE test harness (tests/uae/) can observe
 * whether it started up and is still running/progressing, the same
 * way every synthetic test program in this project already does.
 *
 * Deliberately minimal: no exec.library/dos.library calls, just
 * direct custom-chip register access - works the same whether your
 * program has opened any libraries yet or not, and matches the exact
 * protocol tests/uae/e2e/program.s and every other execram test
 * program already use (9600 baud, 8N1, PAL timing), so no changes are
 * needed on the test-harness side to capture it.
 *
 * Usage:
 *   1. Call exram_serial_init() once, as early as convenient (before
 *      or after your own hardware/library setup - it only touches
 *      SERPER/INTENA/INTREQ, nothing your program is likely to
 *      conflict with).
 *   2. Call exram_serial_puts("EXECRAM-HEXAGON-BOOT-OK\n") once,
 *      right after whatever startup/allocation work your program does
 *      succeeds - before entering the main effect loop. This alone
 *      proves the packed program correctly decompressed, allocated,
 *      relocated, and reached real application code, the same
 *      "boot sentinel" every other execram test program checks for.
 *   3. If your main loop runs indefinitely (typical for a visual
 *      demo), also call exram_serial_putchar('.') (or similar) once
 *      per frame/iteration inside that loop. A steady stream of dots
 *      arriving over serial is a liveness signal distinct from a
 *      one-shot sentinel: it lets a headless test tell "still running
 *      normally" apart from "hung" or "crashed after startup" without
 *      needing to see the screen.
 *
 * No warranty, no license claim over your own code - this file is
 * plain, uncreative hardware-register access; use, copy, or discard
 * freely.
 */

#ifndef EXRAM_SERIAL_H
#define EXRAM_SERIAL_H

#define EXRAM_CUSTOM_BASE 0xdff000UL

#define EXRAM_INTENA (*(volatile unsigned short *)(EXRAM_CUSTOM_BASE + 0x9a))
#define EXRAM_INTREQ (*(volatile unsigned short *)(EXRAM_CUSTOM_BASE + 0x9c))
#define EXRAM_SERPER (*(volatile unsigned short *)(EXRAM_CUSTOM_BASE + 0x32))
#define EXRAM_SERDAT (*(volatile unsigned short *)(EXRAM_CUSTOM_BASE + 0x30))

/* Call once, as early as convenient. Quiets interrupts (matching
 * every other execram test program - avoids an interrupt handler
 * firing mid-transmit) and sets ~9600 baud for PAL timing. */
static void exram_serial_init(void)
{
    EXRAM_INTENA = 0x7fff;
    EXRAM_INTREQ = 0x7fff;
    EXRAM_SERPER = 368; /* (3546895/9600)-1, PAL clock - same constant every execram test program uses */
}

/* Sends one byte. Paces itself with a fixed delay loop rather than
 * polling the transmit-buffer-empty status bit: execram's own test
 * programs found that bit never went high under FS-UAE's serial
 * emulation specifically (see tests/uae/boot/sentinel.s's own header
 * comment), so a fixed delay is what actually works there, not a
 * hardware inaccuracy in your program. Adjust EXRAM_CHAR_DELAY if you
 * need faster transmission and find bytes are arriving corrupted or
 * dropped in practice - this value matches what execram's own test
 * programs already use successfully. */
#define EXRAM_CHAR_DELAY 20000

static void exram_serial_putchar(unsigned char c)
{
    volatile long delay;
    EXRAM_SERDAT = 0x100u | c; /* bit 8 = stop bit, per the Amiga HRM's SERDAT format */
    for (delay = EXRAM_CHAR_DELAY; delay; delay--) {
    }
}

static void exram_serial_puts(const char *s)
{
    while (*s) {
        exram_serial_putchar((unsigned char)*s++);
    }
}

#endif
