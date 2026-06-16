# Windows Host Agent

`SysmonWindowsAgent` is a standalone Windows agent for the ESP32-S3-LCD-1.47
system monitor. It streams the same serial protocol as `host/sysmon.py`, but uses
.NET 10 and `LibreHardwareMonitorLib` directly instead of Python or WMI.

## Requirements

- Windows 10/11
- .NET 10 SDK
- The ESP32 board connected over USB

CPU temperature sensors may require running the app as Administrator, depending
on the machine and sensor driver access.

## Build

```powershell
cd host\windows\SysmonWindowsAgent
dotnet restore
dotnet publish -c Release -r win-x64 --self-contained false
```

For Windows on Arm:

```powershell
dotnet publish -c Release -r win-arm64 --self-contained false
```

## Run

```powershell
dotnet run --project host\windows\SysmonWindowsAgent
```

Or run the published executable:

```powershell
host\windows\SysmonWindowsAgent\bin\Release\net10.0-windows\win-x64\publish\SysmonWindowsAgent.exe
```

The board is auto-detected by Espressif USB VID `303A`. You can override the
port if needed:

```powershell
SysmonWindowsAgent.exe --port COM8
```

Supported options:

- `--port COM8`
- `--baud 115200`
- `--interval 1.0`
