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

import re
import os
import sys
import time
import shlex
import json
import shutil
import platform
import argparse
import threading
import subprocess

import psutil
import serial
import serial.tools.list_ports

ESPRESSIF_VID = 0x303A
BAUD = 115200
MACMON_COMMANDS = (
    ("macmon", "pipe", "-i", "1000"),
    ("/opt/homebrew/bin/macmon", "pipe", "-i", "1000"),
    ("/usr/local/bin/macmon", "pipe", "-i", "1000"),
    ("/opt/local/bin/macmon", "pipe", "-i", "1000"),
)
MAC_TEMP_COMMANDS = (
    ("osx-cpu-temp",),
    ("/opt/homebrew/bin/osx-cpu-temp",),
    ("/usr/local/bin/osx-cpu-temp",),
    ("/opt/local/bin/osx-cpu-temp",),
    ("istats", "cpu", "temp", "--value-only"),
    ("/opt/homebrew/bin/istats", "cpu", "temp", "--value-only"),
    ("/usr/local/bin/istats", "cpu", "temp", "--value-only"),
    ("/opt/local/bin/istats", "cpu", "temp", "--value-only"),
)
WINDOWS_TEMP_SCRIPT = r"""
$namespaces = @('root\LibreHardwareMonitor', 'root\OpenHardwareMonitor')
foreach ($ns in $namespaces) {
    try {
        if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
            $allSensors = Get-WmiObject -Namespace $ns -Class Sensor -ErrorAction Stop
        } else {
            $allSensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
        }
        $sensors = $allSensors | Where-Object {
            $_.SensorType -eq 'Temperature' -and
            ($_.Identifier -match '/(intelcpu|amdcpu|cpu)/' -or
             $_.Name -match 'CPU|Package|Tctl|Tdie|Core')
        }
        if ($sensors) {
            $sensor = $sensors |
                Sort-Object `
                    @{ Expression = { if ($_.Name -match 'Package|Tctl|Tdie|CPU') { 0 } else { 1 } } }, `
                    @{ Expression = 'Value'; Descending = $true } |
                Select-Object -First 1
            [Console]::Out.WriteLine(([double]$sensor.Value).ToString(
                [Globalization.CultureInfo]::InvariantCulture))
            exit 0
        }
    } catch {
    }
}
exit 1
"""


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
def _linux_temp():
    """CPU temperature in °C on Linux; handles Intel (coretemp) and AMD (k10temp)."""
    try:
        t = psutil.sensors_temperatures()
    except (AttributeError, OSError):
        return 0
    src = t.get("coretemp") or t.get("k10temp")
    return int(src[0].current) if src else 0


def _cmd_path(cmd):
    """Return a runnable absolute/path-resolved command, or None if unavailable."""
    exe = cmd[0]
    if os.path.isabs(exe):
        return list(cmd) if os.access(exe, os.X_OK) else None
    path = shutil.which(exe)
    return [path, *cmd[1:]] if path else None


def _macmon_temp(cmd):
    """Build a reader backed by a persistent `macmon pipe` process."""
    lock = threading.Lock()
    state = {"temp": 0, "proc": None}

    def update_temp(line):
        try:
            payload = json.loads(line)
            temp = int(float(payload["temp"]["cpu_temp_avg"]))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            return
        if temp > 0:
            with lock:
                state["temp"] = temp

    def pump(proc):
        if proc.stdout is None:
            return
        for line in proc.stdout:
            update_temp(line)

    def start():
        with lock:
            proc = state["proc"]
            if proc is not None and proc.poll() is None:
                return
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True,
                                    bufsize=1)
        except OSError as e:
            print(f"temperature command failed ({cmd[0]}): {e}", file=sys.stderr)
            return
        with lock:
            state["proc"] = proc
        t = threading.Thread(target=pump, args=(proc,), daemon=True)
        t.start()

    def read():
        start()
        with lock:
            return state["temp"]
    start()
    return read


def _cmd_temp(cmd):
    """Build a reader that runs `cmd` and parses the first positive number as °C."""
    def read():
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
        except (OSError, subprocess.SubprocessError) as e:
            print(f"temperature command failed ({cmd[0]}): {e}", file=sys.stderr)
            return 0
        if proc.returncode != 0:
            err = proc.stderr.strip() or proc.stdout.strip()
            print(f"temperature command failed ({cmd[0]}): {err}", file=sys.stderr)
            return 0
        m = re.search(r"-?\d+(?:\.\d+)?", proc.stdout)
        if not m:
            return 0
        temp = int(float(m.group()))
        return temp if temp > 0 else 0
    return read


def _windows_temp_reader():
    """CPU temperature in °C on Windows via Libre/OpenHardwareMonitor WMI."""
    shell = shutil.which("powershell") or shutil.which("pwsh")
    if not shell:
        print("no Windows PowerShell found; TMP will report 0", file=sys.stderr)
        return lambda: 0

    cmd = [shell, "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-Command", WINDOWS_TEMP_SCRIPT]
    lock = threading.Lock()
    state = {"temp": 0, "started": False, "announced": False}

    def poll():
        while True:
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                      timeout=10)
                m = re.search(r"-?\d+(?:\.\d+)?", proc.stdout)
                temp = int(float(m.group())) if proc.returncode == 0 and m else 0
            except (OSError, subprocess.SubprocessError):
                temp = 0

            if temp > 0:
                with lock:
                    state["temp"] = temp
                    if not state["announced"]:
                        print("using Windows CPU temp source: "
                              "Libre/OpenHardwareMonitor WMI", file=sys.stderr)
                        state["announced"] = True
            time.sleep(5)

    def read():
        with lock:
            if not state["started"]:
                t = threading.Thread(target=poll, daemon=True)
                t.start()
                state["started"] = True
                print("polling Windows CPU temp source: "
                      "Libre/OpenHardwareMonitor WMI", file=sys.stderr)
            return state["temp"]

    return read


def _dedupe_commands(commands):
    """Yield commands once while preserving priority order."""
    seen = set()
    for cmd in commands:
        key = tuple(cmd)
        if not key or key in seen:
            continue
        seen.add(key)
        yield cmd


def make_temp_reader():
    """Pick a CPU-temperature backend once, based on the host OS.

    Linux uses psutil's sensors. macOS has no psutil sensor support, so it falls
    back to a CLI tool if installed (`osx-cpu-temp` or `istats`); otherwise temp
    reports 0 and the rest of the stats stream normally. Set SYSMON_TEMP_CMD to
    override the macOS helper command.
    """
    system = platform.system()
    if system == "Linux":
        return _linux_temp
    if system == "Windows":
        return _windows_temp_reader()
    if system == "Darwin":
        configured = os.environ.get("SYSMON_TEMP_CMD", "").strip()
        candidates = [tuple(shlex.split(configured))] if configured else []
        candidates.extend(MACMON_COMMANDS)
        candidates.extend(MAC_TEMP_COMMANDS)

        found = []
        tried = set()
        for candidate in _dedupe_commands(candidates):
            cmd = _cmd_path(candidate)
            if not cmd:
                continue
            key = tuple(cmd)
            if key in tried:
                continue
            tried.add(key)
            found.append(" ".join(cmd))
            if os.path.basename(cmd[0]) == "macmon":
                reader = _macmon_temp(cmd)
                print(f"using macOS CPU temp source: {' '.join(cmd)}",
                      file=sys.stderr)
                return reader
            else:
                reader = _cmd_temp(cmd)
            if reader() > 0:
                print(f"using macOS CPU temp source: {' '.join(cmd)}",
                      file=sys.stderr)
                return reader

        if found:
            print("macOS CPU temp helpers were found but returned no valid "
                  f"temperature ({'; '.join(found)}); TMP will report 0",
                  file=sys.stderr)
        else:
            print("no macOS CPU temp source found (install macmon, "
                  "osx-cpu-temp, or iStats, or set SYSMON_TEMP_CMD); "
                  "TMP will report 0",
                  file=sys.stderr)
    return lambda: 0


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

    read_temp = make_temp_reader()
    ser = open_serial()
    psutil.cpu_percent(None)                # prime: first call always returns 0
    last = psutil.net_io_counters()

    while True:
        time.sleep(args.interval)
        cpu = int(psutil.cpu_percent(None))
        mem = int(psutil.virtual_memory().percent)
        tmp = read_temp()
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
