# USB System Monitor — Project Brief

A hardware system monitor: a Waveshare **ESP32-S3-LCD-1.47** plugs into a PC via its
USB Type-A plug and displays live host stats (CPU, memory, temperature, network
throughput) on its 172×320 LCD. A small agent on the host reads the stats and streams
them to the board over a USB CDC serial link.

This document is the implementation spec. Build it in two parts (host agent + firmware)
and follow the **Constraints** section exactly — those items are non-obvious failure
modes, not suggestions.

---

## Goal / definition of done

- Plug the board into a Fedora PC → it enumerates as a serial port; the agent finds it automatically.
- The agent streams one stats line per second.
- The LCD shows CPU% and MEM% as arc gauges, CPU temperature as a number, and RX/TX throughput.
- The onboard RGB LED reflects CPU load (green → red).
- If the host stops sending (agent killed, board replugged), the board greys the gauges and shows "waiting for host" within ~3 s, then recovers automatically when data resumes.
- The agent survives the board being unplugged/replugged (reconnect loop).

---

## Hardware

**Board:** Waveshare ESP32-S3-LCD-1.47 — ESP32-S3 (dual LX7 @ 240 MHz), 8 MB PSRAM,
16 MB flash, Wi-Fi + BLE 5 (LE only — **no Bluetooth Classic**), ST7789 LCD 172×320,
microSD (SDMMC-capable), one WS2812 RGB LED, native USB on a **Type-A male** plug.

**Pinout (verified from the Waveshare wiki) — do not reassign these:**

| Function                         | GPIO                        |
| -------------------------------- | --------------------------- |
| LCD MOSI                         | 45                          |
| LCD SCLK                         | 40                          |
| LCD CS                           | 42                          |
| LCD DC                           | 41                          |
| LCD RST                          | 39                          |
| LCD BL (backlight)               | 48                          |
| SD CLK / CMD / D0 / D1 / D2 / D3 | 14 / 15 / 16 / 18 / 17 / 21 |
| RGB LED (WS2812, 1 pixel)        | 38                          |
| Native USB D− / D+               | 19 / 20                     |

Free GPIOs (4–13) are available but this project needs none of them.

**Host:** a PC running Fedora (Python 3). NVIDIA/AMD GPU optional.

---

## Architecture

```
[ Fedora PC ]                         [ ESP32-S3 board ]
 psutil  ──►  sysmon.py  ──USB CDC──►  read line ──► parse ──► LVGL gauges
 (stats)      (1 Hz)     /dev/ttyACM0               update widgets + RGB LED
```

The board's native USB enumerates as a CDC-ACM device, so the "link" is just
newline-delimited text over a serial port. The board is a USB **device**, not a host —
it presents itself to the PC; it cannot read other USB peripherals.

---

## Repository layout

```
usb-sysmon/
├── README.md
├── host/
│   ├── sysmon.py
│   ├── requirements.txt
│   └── usb-sysmon.service        # systemd --user unit
└── firmware/
    └── usb_sysmon/               # Arduino sketch (default) — see Firmware section
        └── usb_sysmon.ino
```

---

## Line protocol

Newline-terminated `KEY:value` pairs, integers only (no floats to parse on the MCU).
Order-independent and extensible:

```
CPU:42,MEM:67,TMP:58,RX:1234,TX:88\n
```

- `CPU`, `MEM` — percent (0–100)
- `TMP` — CPU temperature, °C
- `RX`, `TX` — network throughput, KB/s

---

## Part 1 — Host agent (Python, Fedora)

`host/requirements.txt`:

```
psutil
pyserial
```

`host/sysmon.py` — reference implementation; productionise the reconnect handling and
add an optional GPU field:

```python
import psutil, serial, serial.tools.list_ports, time, sys

ESPRESSIF_VID = 0x303A

def find_port():
    for p in serial.tools.list_ports.comports():
        if p.vid == ESPRESSIF_VID:
            return p.device
    return None

def open_serial():
    while True:
        port = find_port()
        if port:
            try:
                return serial.Serial(port, 115200, timeout=1)
            except serial.SerialException:
                pass
        print("waiting for board...", file=sys.stderr)
        time.sleep(2)

def cpu_temp():
    t = psutil.sensors_temperatures()
    src = t.get("coretemp") or t.get("k10temp")   # Intel vs AMD
    return int(src[0].current) if src else 0

def main():
    ser = open_serial()
    psutil.cpu_percent(None)                       # prime: first call returns 0
    last = psutil.net_io_counters()
    while True:
        time.sleep(1)
        cpu = int(psutil.cpu_percent(None))
        mem = int(psutil.virtual_memory().percent)
        tmp = cpu_temp()
        now = psutil.net_io_counters()
        rx = (now.bytes_recv - last.bytes_recv) // 1024
        tx = (now.bytes_sent - last.bytes_sent) // 1024
        last = now
        line = f"CPU:{cpu},MEM:{mem},TMP:{tmp},RX:{rx},TX:{tx}\n"
        try:
            ser.write(line.encode())
        except serial.SerialException:
            ser = open_serial()                    # board replugged → reconnect

if __name__ == "__main__":
    main()
```

`host/usb-sysmon.service` (systemd `--user` unit so it auto-starts and restarts):

```ini
[Unit]
Description=USB system monitor agent
After=default.target

[Service]
ExecStart=/usr/bin/python3 %h/usb-sysmon/host/sysmon.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
```

Install: `systemctl --user enable --now usb-sysmon.service`.

**Host gotchas (must handle):**

- The user must be in the `dialout` group (`sudo usermod -aG dialout $USER`, then re-login) or the port open fails with permission denied. Document this in the README.
- CPU temperature sensor key differs by vendor: `coretemp` (Intel) vs `k10temp` (AMD). Handle both (done above).
- `psutil.cpu_percent()` returns 0 on its first call — prime it once before the loop.
- Network throughput is a delta of `net_io_counters()` between samples, not an absolute.
- GPU stats are vendor-specific and optional: `pynvml` (NVIDIA) or `rocm-smi`/sysfs (AMD). Add a `GPU:` field only after the core fields work; degrade gracefully if absent.

---

## Part 2 — Firmware

**Framework: Arduino (default).** Rationale: Waveshare ships an Arduino + LVGL demo for
this exact board, which already handles ST7789 bring-up (including the panel's column
offset). Reuse that demo as the display scaffold — do **not** write a panel driver from
scratch. An ESP-IDF alternative is described at the end; if the team prefers ESP-IDF,
swap the USB and display layers per those notes and keep everything else.

In the Arduino IDE board settings, set **USB CDC On Boot: Enabled** so `Serial` maps to
the native USB. Use the WS2812 via `Adafruit_NeoPixel` or `FastLED` (1 pixel, GPIO 38).

`firmware/usb_sysmon/usb_sysmon.ino` — skeleton to complete:

```cpp
#include <lvgl.h>
// #include "waveshare_display.h"   // from the vendor LVGL demo: panel + lv_disp init
#include <Adafruit_NeoPixel.h>

Adafruit_NeoPixel led(1, 38, NEO_GRB + NEO_KHZ800);

// --- parsed stats (written in loop, read in loop — single-threaded, so no lock) ---
int cpu = 0, mem = 0, tmp = 0, rx = 0, tx = 0;
unsigned long last_rx_ms = 0;       // last time a valid line arrived

// --- LVGL widgets ---
lv_obj_t *cpu_arc, *mem_arc, *tmp_lbl, *net_lbl, *status_lbl;

char line[96];
int  idx = 0;

void build_ui() {
  // Portrait 172x320. Suggested layout:
  //   top:    CPU arc (label "CPU" + % in center)
  //   middle: MEM arc (label "MEM" + % in center)
  //   below:  tmp_lbl  "58°C"
  //   bottom: net_lbl  "1234 / 88 KB/s"
  //   overlay status_lbl "waiting for host" (hidden when data is live)
  // Create cpu_arc, mem_arc as lv_arc with range 0..100.
}

void apply_stats() {
  lv_arc_set_value(cpu_arc, cpu);
  lv_arc_set_value(mem_arc, mem);
  lv_label_set_text_fmt(tmp_lbl, "%d\u00B0C", tmp);
  lv_label_set_text_fmt(net_lbl, "%d / %d KB/s", rx, tx);
  // RGB: green (low) -> red (high) by CPU load
  led.setPixelColor(0, led.Color((cpu * 255) / 100, (255 - cpu * 255 / 100), 0));
  led.show();
}

void parse(const char *s) {
  if (sscanf(s, "CPU:%d,MEM:%d,TMP:%d,RX:%d,TX:%d",
             &cpu, &mem, &tmp, &rx, &tx) == 5) {
    last_rx_ms = millis();
    lv_obj_add_flag(status_lbl, LV_OBJ_FLAG_HIDDEN);
    apply_stats();
  }
}

void setup() {
  Serial.begin(115200);
  led.begin();
  // display_init();      // call the vendor demo's panel + LVGL init here
  build_ui();
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n') { line[idx] = 0; idx = 0; parse(line); }
    else if (idx < (int)sizeof(line) - 1) line[idx++] = c;
  }
  // disconnect detection: no valid line for >3 s -> show waiting state
  if (millis() - last_rx_ms > 3000) {
    lv_obj_clear_flag(status_lbl, LV_OBJ_FLAG_HIDDEN);
    // optionally grey the arcs / set RGB to dim blue
  }
  lv_timer_handler();
  delay(5);
}
```

### UI spec (172×320 portrait)

- Two stacked `lv_arc` gauges: CPU (top), MEM (middle), each with its label and a
  centered `%` value.
- `tmp_lbl`: large temperature readout below the arcs.
- `net_lbl`: RX / TX throughput at the bottom.
- `status_lbl`: a centered overlay reading "waiting for host", hidden while data is live.
- Optional stretch: an `lv_chart` scrolling CPU-history strip.

### Firmware constraints (must follow)

- **LVGL is not thread-safe.** This design keeps serial reading and `lv_timer_handler()`
  in the _same_ `loop()`, so widgets are only touched from one context — keep it that
  way. If you ever move serial reading into a separate task/core, you **must** guard all
  `lv_*` calls with a mutex (or LVGL 9's `lv_lock`/`lv_unlock`).
- **Reuse the vendor display init.** The ST7789 here is a 172-wide panel sitting in a
  240-wide controller RAM, so it needs a column offset (commonly 34 px). The Waveshare
  demo already sets this. If you bring up the panel yourself and the image is shifted
  sideways, that offset is the cause.
- Port autodetect on the host filters by USB VID `0x303A` (Espressif). Confirm the VID
  the board actually presents (see Verify section).

### ESP-IDF alternative

If using ESP-IDF instead of Arduino:

- Replace `Serial` with the `usb_serial_jtag` driver
  (`usb_serial_jtag_driver_install()` + `usb_serial_jtag_read_bytes()` into the same
  line buffer).
- **Route `ESP_LOGx` off the USB-Serial/JTAG channel** (to UART0, or lower the console
  log level), or log spam will share the channel the host is talking on. For a fully
  separate data port that leaves the JTAG console free for flashing/logs, use TinyUSB
  CDC (`esp_tinyusb` + `tusb_cdc_acm_init`) instead.
- Mount the SD (if ever used) with `esp_vfs_fat_sdmmc_mount` on the SDMMC pins above;
  do not rely on `audio_board_*` helpers.

---

## README (build & run) — summarise these steps

1. `cd host && pip install -r requirements.txt`
2. Add user to `dialout`, re-login.
3. Flash `firmware/usb_sysmon` to the board (Arduino IDE: select ESP32S3 Dev Module,
   USB CDC On Boot = Enabled). If flashing fails, enter download mode: hold BOOT, tap
   RESET, release BOOT.
4. Plug board into the PC; confirm `/dev/ttyACM*` appears (`dmesg | tail`).
5. `python3 host/sysmon.py` (or enable the systemd user service).

---

## Verify against hardware/docs (do not assume — confirm)

- The USB VID/PID the board presents on Fedora (`lsusb`, or `udevadm info` on the
  `/dev/ttyACM*` node). Adjust `ESPRESSIF_VID`/add a PID filter if needed.
- The exact ST7789 column offset used by the vendor demo (≈34, but confirm).
- The LVGL major version bundled with the vendor demo (8 vs 9) — a few APIs differ
  (locking, some label/style calls).
- That the Type-A plug routes to the native USB (GPIO 19/20). Either way a serial port
  appears, but confirm the device path before wiring up autodetect.
- WS2812 pixel count is 1 on GPIO 38.

---

## Stretch goals

- GPU load/temp field (NVIDIA `pynvml` / AMD `rocm-smi`).
- Scrolling CPU/MEM history charts.
- Per-core CPU bars.
- A second "screen" (disk/IO or top process) toggled by the BOOT button.
- Brightness control via `LCD_BL` (GPIO 48) PWM, dimming when idle.
