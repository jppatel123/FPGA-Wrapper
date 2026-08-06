#!/usr/bin/env python3
"""
send_hex.py

Sends a RARS-generated instruction memory file to the FPGA over the
JTAG UART, so RISCV_Processor's instruction memory gets loaded without
needing to recompile the FPGA every time you change your program.

USAGE:
    python3 send_hex.py imem.hex

HOW TO GET imem.hex FROM RARS:
    File -> Dump Memory -> select ".text" -> format "Hexadecimal Text"
    -> save as imem.hex

WHAT THIS SCRIPT ACTUALLY DOES (in plain terms):
    Your FPGA design has a small piece of hardware (uart_loader) sitting
    between the JTAG UART and the processor's instruction memory. It's
    waiting for bytes to arrive. This script's whole job is just: turn
    your instructions into the right sequence of bytes, and push them
    through the JTAG cable using a program called nios2-terminal (this
    comes with Quartus -- it's a generic "talk to a JTAG UART" tool, it
    has nothing to do with Nios II processors specifically).

    After every instruction's 4 bytes, uart_loader is expecting one
    special 4-byte marker (0xDEADBEEF) that tells it "that's the last
    instruction, stop waiting for more." This script appends that marker
    automatically -- you don't need to add it to your RARS program.

WHY THIS SCRIPT CAN'T TELL YOU IF THE LOAD ACTUALLY WORKED:
    Once bytes leave this script over the JTAG cable, this script has NO
    way to look inside the FPGA and check what happened to them. The
    board's LEDs are the only real confirmation:
      - LEDR should count up to your instruction count WHILE this script
        is running (watch it live, not just at the end).
      - LEDG3 should turn ON once the load is fully done.
      - LEDG4 should turn ON once the processor actually finishes running
        and reaches WFI (halt) -- this comes from a real signal inside
        the processor (oHalt), not a guess, so it only lights up when the
        program has genuinely completed.
    If LEDR never reaches the right number, or LEDG3 never turns on,
    the load did not complete -- rerun this script (SW2 up-then-down on
    the board first, to reset the loader for a fresh attempt).
"""

import subprocess
import struct
import sys
import os
import time
import shutil

# The 4-byte marker that tells uart_loader "no more instructions coming."
# Must match the sentinel uart_loader.vhd is built to recognize.
END_SENTINEL = 0xDEADBEEF

# Where Quartus installs nios2-terminal. Adjust this if yours lives
# somewhere else, or just make sure it's on your PATH.
NIOS2_TERMINAL = "/usr/local/quartus/25.1/quartus/bin/nios2-terminal"

# How long to wait for nios2-terminal to attach to the JTAG chain before
# assuming something's wrong (board not programmed, cable issue, etc.)
ATTACH_WAIT_S = 1.5

# How long to wait for all the bytes to actually finish draining through
# the JTAG cable before shutting nios2-terminal down. This is deliberately
# generous: the JTAG UART's internal buffer is small (64 bytes) and
# real-world throughput over JTAG is much slower than a regular UART, so
# for anything beyond a handful of instructions, this needs real margin --
# cutting the connection early silently truncates the transfer, and it's
# easy to mistake that for a hardware bug instead of a timing setting.
MIN_DRAIN_WAIT_S = 3.0
ASSUMED_BYTES_PER_SEC = 300  # conservative on purpose


def find_terminal():
    if os.path.isfile(NIOS2_TERMINAL):
        return NIOS2_TERMINAL
    on_path = shutil.which("nios2-terminal")
    if on_path:
        return on_path
    print(f"ERROR: couldn't find nios2-terminal at {NIOS2_TERMINAL}, and")
    print("it's not on your PATH either.")
    print("Fix: edit the NIOS2_TERMINAL constant near the top of this file")
    print("to point at your actual Quartus install.")
    sys.exit(1)


def check_no_other_terminal_running():
    """The JTAG UART only allows one program to talk to it at a time.
    A leftover nios2-terminal (or an open Quartus Programmer window)
    will block this script from connecting."""
    result = subprocess.run(["pgrep", "-f", "nios2-terminal"],
                             capture_output=True, text=True)
    pids = [p for p in result.stdout.split() if p and int(p) != os.getpid()]
    if pids:
        print(f"ERROR: nios2-terminal is already running (PID {', '.join(pids)}).")
        print("Close it, and make sure Quartus Programmer is closed too,")
        print("then run this script again.")
        sys.exit(1)


def read_hex_file(hex_path):
    """Reads one hex instruction per line. Skips blank lines, comments,
    and RARS's occasional 'v2' header line."""
    words = []
    with open(hex_path, "r") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            if line.lower().startswith("v2"):
                continue
            try:
                words.append(int(line, 16))
            except ValueError:
                print(f"  (skipping line {lineno}, not a valid hex value: {line!r})")
    return words


def build_byte_stream(words):
    """Turns each 32-bit instruction into 4 bytes, most-significant byte
    first -- this has to match the order uart_loader.vhd assembles bytes
    back into a word, or every instruction will come out scrambled.
    Appends the END_SENTINEL marker at the end."""
    stream = b"".join(struct.pack(">I", w) for w in words)
    stream += struct.pack(">I", END_SENTINEL)
    return stream


def send_over_jtag_uart(terminal_path, byte_stream):
    print("  -> launching nios2-terminal...")
    proc = subprocess.Popen([terminal_path], stdin=subprocess.PIPE)

    print(f"  -> giving it {ATTACH_WAIT_S}s to attach to the JTAG chain...")
    time.sleep(ATTACH_WAIT_S)

    if proc.poll() is not None:
        print(f"ERROR: nios2-terminal quit immediately (exit code {proc.returncode}).")
        print("Most common causes:")
        print("  - the FPGA hasn't been programmed with a .sof yet")
        print("  - another nios2-terminal or an open Quartus Programmer")
        print("    window is holding the JTAG cable")
        sys.exit(1)

    print(f"  -> sending {len(byte_stream)} bytes...")
    try:
        proc.stdin.write(byte_stream)
        proc.stdin.flush()
    except BrokenPipeError:
        print("ERROR: the connection dropped while sending. Check")
        print("nios2-terminal's own message above this for the reason.")
        sys.exit(1)

    print("  -> telling nios2-terminal there's no more data coming...")
    proc.stdin.close()

    drain_wait = max(MIN_DRAIN_WAIT_S, len(byte_stream) / ASSUMED_BYTES_PER_SEC)
  
    time.sleep(drain_wait)

    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 send_hex.py <imem.hex>")
        print()
        print("To create imem.hex in RARS:")
        print("  File -> Dump Memory -> .text -> Hexadecimal Text -> imem.hex")
        sys.exit(1)

    hex_path = sys.argv[1]
    if not os.path.isfile(hex_path):
        print(f"ERROR: no such file: {hex_path}")
        sys.exit(1)

    terminal_path = find_terminal()
    check_no_other_terminal_running()

    words = read_hex_file(hex_path)
    if not words:
        print(f"ERROR: found zero valid instructions in {hex_path}.")
        print("Did you dump the .text segment (not .data), in Hexadecimal Text format?")
        sys.exit(1)

    if END_SENTINEL in words:
        print("ERROR: your program contains the value 0xDEADBEEF, which is")
        print("reserved as the 'end of program' marker. Change the sentinel")
        print("value in both this script and uart_loader.vhd if you need")
        print("that literal value in your program.")
        sys.exit(1)

    print(f"Found {len(words)} instructions in {hex_path}.")
    print()
    print(f"Loading {len(words)} instructions onto the FPGA:")

    byte_stream = build_byte_stream(words)
    send_over_jtag_uart(terminal_path, byte_stream)

    print()
    print("=" * 60)
    print("Send finished. ")
    
    print()
    print(f"  1. LEDR should show {len(words)} in binary, and should have")
    print("     counted UP to that live while this script was running")
    print("     (watch it next time instead of just checking after)")
    print("  2. LEDG3 should be ON now (this means load_done -- the FPGA")
    print("     saw the end marker and the load is complete)")
    print("  3. LEDG4 should turn ON once the processor finishes running")
    print("     and genuinely reaches the WFI (halt) instruction -- this")
    print("     is a real signal from inside the processor now, not a guess,")
    print("     so if it's on, the program actually completed correctly")
    print()
    print("If LEDG3 never turns on, the load itself did not finish.")
    print("If LEDG3 is on but LEDG4 never turns on, the load worked but")
    print("the processor hasn't reached WFI yet -- for programs with loops")
    print("or recursion this can take a while, give it a moment.")
    print()
    print("Either way, flip SW2 up then down on the board to reset the")
    print("loader before trying again.")
    print("=" * 60)


if __name__ == "__main__":
    main()
