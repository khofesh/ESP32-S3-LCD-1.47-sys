# USB System Monitor — ESP32-S3-LCD-1.47

A hardware system monitor. The Waveshare **ESP32-S3-LCD-1.47** plugs into a PC
over its USB Type-A plug and shows live host stats on its 172×320 LCD:

- **CPU** and **MEM** as arc gauges (with centered %)
- **CPU temperature** as a large readout
- **RX / TX** network throughput
- the onboard **RGB LED** shifts green → red with CPU load

A small Python agent on the host samples the stats with `psutil` and streams one
line per second to the board over the native USB CDC serial link. If the host
stops sending, the board greys the gauges and shows **"waiting for host"** within
~3 s, then recovers automatically when data resumes.

See `CLAUDE.md` for the full spec.

## Layout

```
.                       # ESP-IDF firmware project (this repo)
├── main/
│   └── Sysmon/         # the system-monitor module: USB link + LVGL UI
│       ├── sysmon.c
│       └── sysmon.h
└── host/               # Python host agent
    ├── sysmon.py
    ├── requirements.txt
    └── usb-sysmon.service   # systemd --user unit
```

The firmware is built with **ESP-IDF** (not the Arduino default from the spec):
it reuses the Waveshare ESP-IDF + LVGL 8.3 display scaffold already in this repo
(ST7789 bring-up, including the 34 px column offset, and the WS2812 driver).

## Line protocol

Newline-terminated `KEY:value` pairs, integers only:

```
CPU:42,MEM:67,TMP:58,RX:1234,TX:88\n
```

- `CPU`, `MEM` — percent (0–100)
- `TMP` — CPU temperature, °C
- `RX`, `TX` — network throughput, KB/s
- `GPU` — optional GPU utilisation % (NVIDIA, with `--gpu`)

## Host agent (Fedora)

1. Install deps:
   ```sh
   cd host && pip install -r requirements.txt
   ```
2. Add yourself to `dialout` so the serial port can be opened, then **re-login**:
   ```sh
   sudo usermod -aG dialout $USER
   ```
3. Run it:

   ```sh
   python3 host/sysmon.py            # core fields
   python3 host/sysmon.py --gpu      # also stream GPU% if an NVIDIA GPU is present
   ```

   The agent auto-detects the board by USB VID `0x303A` (Espressif) and
   reconnects automatically if the board is unplugged/replugged.

   To auto-start it, install the user service (edit `ExecStart` to this repo's
   path first):

   ```sh
   cp host/usb-sysmon.service ~/.config/systemd/user/
   systemctl --user enable --now usb-sysmon.service
   ```

## Firmware

Requires ESP-IDF (developed against **v6.0.1**). With the environment exported:

```sh
idf.py set-target esp32s3      # already configured in this repo
idf.py build
idf.py -p /dev/ttyACM0 flash monitor
```

If flashing fails, enter download mode: hold **BOOT**, tap **RESET**, release
**BOOT**, then retry.

### Notes

- The data link uses the chip's built-in **USB-Serial/JTAG** peripheral
  (GPIO 19/20). The board enumerates as `/dev/ttyACM*` with VID `0x303A`.
- `ESP_LOGx` output goes to **UART0** (the project's primary console), so logs
  never contend with the host data on the USB channel.
- Serial reading, parsing, widget updates, and the RGB LED are all driven from a
  single LVGL timer in the same context as `lv_timer_handler()`, so no LVGL
  locking is required.
