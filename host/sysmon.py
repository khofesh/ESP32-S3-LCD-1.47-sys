#!/usr/bin/env python3
"""USB system monitor — host agent.

Streams one stats line per second to the ESP32-S3-LCD-1.47 board over its native
USB CDC serial link. The board parses the line and renders CPU/MEM gauges, CPU
temperature, and RX/TX throughput (see CLAUDE.md for the protocol).

Line protocol (newline-terminated, integers only):

    CPU:42,MEM:67,TMP:58,RX:1234,TX:88\n

The agent auto-detects the board by USB VID (Espressif, 0x303A) and survives the
board being unplugged/replugged via a reconnect loop.
"""

import sys
import time
import argparse

import psutil
import serial
import serial.tools.list_ports

ESPRESSIF_VID = 0x303A
BAUD = 115200


# --------------------------------------------------------------------------- #
# Optional GPU support (NVIDIA via pynvml). Degrades gracefully if unavailable.
# --------------------------------------------------------------------------- #
_nvml_handle = None


def gpu_init():
    """Return True if an NVIDIA GPU is available for monitoring."""
    global _nvml_handle
    try:
        import pynvml
        pynvml.nvmlInit()
        if pynvml.nvmlDeviceGetCount() > 0:
            _nvml_handle = pynvml.nvmlDeviceGetHandleByIndex(0)
            return True
    except Exception:
        pass
    return None


def gpu_load():
    """GPU utilisation percent, or None if unavailable."""
    if _nvml_handle is None:
        return None
    try:
        import pynvml
        return int(pynvml.nvmlDeviceGetUtilizationRates(_nvml_handle).gpu)
    except Exception:
        return None


# --------------------------------------------------------------------------- #
# Serial port discovery / connection
# --------------------------------------------------------------------------- #
def find_port():
    for p in serial.tools.list_ports.comports():
        if p.vid == ESPRESSIF_VID:
            return p.device
    return None


def open_serial():
    """Block until the board is present and a serial connection is open."""
    announced = False
    while True:
        port = find_port()
        if port:
            try:
                ser = serial.Serial(port, BAUD, timeout=1)
                print(f"connected to {port}", file=sys.stderr)
                return ser
            except serial.SerialException as e:
                print(f"open failed on {port}: {e}", file=sys.stderr)
        if not announced:
            print("waiting for board...", file=sys.stderr)
            announced = True
        time.sleep(2)


# --------------------------------------------------------------------------- #
# Stats sampling
# --------------------------------------------------------------------------- #
def cpu_temp():
    """CPU temperature in °C; handles Intel (coretemp) and AMD (k10temp)."""
    try:
        t = psutil.sensors_temperatures()
    except (AttributeError, OSError):
        return 0
    src = t.get("coretemp") or t.get("k10temp")
    return int(src[0].current) if src else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--interval", type=float, default=1.0,
                    help="seconds between samples (default: 1.0)")
    ap.add_argument("--gpu", action="store_true",
                    help="include a GPU:<util%%> field if an NVIDIA GPU is present")
    args = ap.parse_args()

    have_gpu = args.gpu and gpu_init()
    if args.gpu and not have_gpu:
        print("GPU requested but no NVIDIA GPU / pynvml available; skipping",
              file=sys.stderr)

    ser = open_serial()
    psutil.cpu_percent(None)                # prime: first call always returns 0
    last = psutil.net_io_counters()

    while True:
        time.sleep(args.interval)
        cpu = int(psutil.cpu_percent(None))
        mem = int(psutil.virtual_memory().percent)
        tmp = cpu_temp()
        now = psutil.net_io_counters()
        rx = max(0, (now.bytes_recv - last.bytes_recv)) // 1024
        tx = max(0, (now.bytes_sent - last.bytes_sent)) // 1024
        last = now

        line = f"CPU:{cpu},MEM:{mem},TMP:{tmp},RX:{rx},TX:{tx}"
        if have_gpu:
            g = gpu_load()
            if g is not None:
                line += f",GPU:{g}"
        line += "\n"

        try:
            ser.write(line.encode())
        except serial.SerialException:
            print("link lost, reconnecting...", file=sys.stderr)
            try:
                ser.close()
            except Exception:
                pass
            ser = open_serial()             # board replugged → reconnect


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
