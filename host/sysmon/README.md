# macOS Swift host agent

This command-line agent samples macOS CPU, memory, network, and Apple Silicon
temperature data, then sends the firmware-compatible line protocol over USB CDC:

```text
CPU:42,MEM:67,TMP:58,RX:1234,TX:88
```

## Requirements

- macOS 13 or newer
- Xcode command-line tools
- an Apple Silicon Mac for the current direct temperature implementation

Temperature uses macOS HID sensor services. If compatible processor-die sensors
are unavailable, the agent keeps running and reports `TMP:0`.

## Build and run with Swift Package Manager

From this directory:

```sh
swift build
swift run sysmon
```

For an optimized binary:

```sh
swift build -c release
.build/release/sysmon
```

The agent prefers serial devices whose USB registry reports Espressif vendor ID
`0x303A`, then falls back to common `/dev/cu.usb*` serial names. It configures
the selected port for 115200 baud and reconnects every two seconds after an
unplug or write failure.

## Test

```sh
swift test
```

The tests cover protocol formatting, CPU delta calculation, elapsed-time network
rates, counter resets, and overflow handling.

## Build with Xcode

Open:

```text
host/sysmon/sysmon.xcodeproj
```

The Xcode target and Swift package share the files in `host/sysmon/sysmon/`.

For a command-line Xcode build without code signing:

```sh
xcodebuild \
  -project sysmon.xcodeproj \
  -scheme sysmon \
  -derivedDataPath /tmp/sysmon-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Install for launchd

Build and copy the binary:

```sh
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/sysmon ~/.local/bin/usb-sysmon
```

Edit `host/com.usbsysmon.agent.plist` and replace `CHANGE_ME` with your macOS
username. Then install it:

```sh
cp ../com.usbsysmon.agent.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/com.usbsysmon.agent.plist
```

To stop and remove it:

```sh
launchctl bootout gui/$(id -u) \
  ~/Library/LaunchAgents/com.usbsysmon.agent.plist
rm ~/Library/LaunchAgents/com.usbsysmon.agent.plist
```

Logs are written to:

```text
/tmp/usb-sysmon.out.log
/tmp/usb-sysmon.err.log
```

## Hardware verification

With the board connected, confirm:

1. Protocol lines appear once per second.
2. `TMP` is nonzero on a supported Apple Silicon Mac.
3. RX/TX react to network traffic.
4. Unplugging the board causes a write failure and reconnect loop.
5. Replugging the board resumes protocol output without restarting the agent.
