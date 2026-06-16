using System.Diagnostics;
using System.Globalization;
using System.IO.Ports;
using System.Management;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using LibreHardwareMonitor.Hardware;

const int EspressifVid = 0x303A;
var options = Options.Parse(args);
using var done = new ManualResetEventSlim(false);
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    done.Set();
};

using var sampler = new MetricsSampler();
var lastNet = NetCounters.Read();

while (!done.IsSet)
{
    using var serial = OpenSerial(options, done);
    if (serial is null)
    {
        break;
    }

    while (!done.Wait(TimeSpan.FromSeconds(options.IntervalSeconds)))
    {
        var nowNet = NetCounters.Read();
        var rx = Math.Max(0, nowNet.RxBytes - lastNet.RxBytes) / 1024;
        var tx = Math.Max(0, nowNet.TxBytes - lastNet.TxBytes) / 1024;
        lastNet = nowNet;

        var sample = sampler.Read();
        var line = FormattableString.Invariant(
            $"CPU:{sample.CpuPercent},MEM:{sample.MemoryPercent},TMP:{sample.CpuTempC},RX:{rx},TX:{tx}\n");

        try
        {
            serial.Write(line);
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or TimeoutException)
        {
            Console.Error.WriteLine("link lost, reconnecting...");
            break;
        }
    }
}

static SerialPort? OpenSerial(Options options, ManualResetEventSlim done)
{
    var announced = false;
    while (!done.IsSet)
    {
        var port = options.PortName ?? FindEspressifPort();
        if (port is not null)
        {
            try
            {
                var serial = new SerialPort(port, options.BaudRate)
                {
                    NewLine = "\n",
                    WriteTimeout = 1000,
                    ReadTimeout = 1000,
                    DtrEnable = true,
                    RtsEnable = true,
                };
                serial.Open();
                Console.Error.WriteLine($"connected to {port}");
                return serial;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                Console.Error.WriteLine($"open failed on {port}: {e.Message}");
            }
        }

        if (!announced)
        {
            Console.Error.WriteLine("waiting for board...");
            announced = true;
        }
        done.Wait(TimeSpan.FromSeconds(2));
    }
    return null;
}

static string? FindEspressifPort()
{
    var vid = $"VID_{EspressifVid:X4}";
    try
    {
        using var searcher = new ManagementObjectSearcher(
            "SELECT Name, PNPDeviceID FROM Win32_PnPEntity WHERE Name LIKE '%(COM%'");
        foreach (ManagementObject device in searcher.Get())
        {
            var pnpId = device["PNPDeviceID"]?.ToString() ?? "";
            if (!pnpId.Contains(vid, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var name = device["Name"]?.ToString() ?? "";
            var match = Regex.Match(name, @"\((COM\d+)\)");
            if (match.Success)
            {
                return match.Groups[1].Value;
            }
        }
    }
    catch (ManagementException e)
    {
        Console.Error.WriteLine($"port discovery failed: {e.Message}");
    }

    return null;
}

sealed class MetricsSampler : IDisposable
{
    private readonly Computer _computer = new()
    {
        IsCpuEnabled = true,
        IsMotherboardEnabled = true,
    };

    public MetricsSampler()
    {
        _computer.Open();
    }

    public Sample Read()
    {
        foreach (var hardware in _computer.Hardware)
        {
            Update(hardware);
        }

        return new Sample(
            CpuPercent: ReadCpuLoad(),
            MemoryPercent: ReadMemoryLoad(),
            CpuTempC: ReadCpuTemp());
    }

    public void Dispose()
    {
        _computer.Close();
    }

    private int ReadCpuLoad()
    {
        var cpu = CpuSensors()
            .Where(s => s.SensorType == SensorType.Load)
            .OrderBy(s => s.Name.Equals("CPU Total", StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .ThenByDescending(s => s.Value ?? 0)
            .FirstOrDefault();
        return ClampPercent(cpu?.Value);
    }

    private int ReadCpuTemp()
    {
        var temp = CpuSensors()
            .Where(s => s.SensorType == SensorType.Temperature)
            .OrderBy(s => IsPackageTemp(s.Name) ? 0 : 1)
            .ThenByDescending(s => s.Value ?? 0)
            .FirstOrDefault();
        return PositiveInt(temp?.Value);
    }

    private IEnumerable<ISensor> CpuSensors()
    {
        foreach (var hardware in _computer.Hardware)
        {
            foreach (var sensor in SensorsFor(hardware))
            {
                if (sensor.Hardware.HardwareType == HardwareType.Cpu ||
                    sensor.Identifier.ToString().Contains("/cpu", StringComparison.OrdinalIgnoreCase))
                {
                    yield return sensor;
                }
            }
        }
    }

    private static IEnumerable<ISensor> SensorsFor(IHardware hardware)
    {
        foreach (var sensor in hardware.Sensors)
        {
            yield return sensor;
        }

        foreach (var child in hardware.SubHardware)
        {
            foreach (var sensor in SensorsFor(child))
            {
                yield return sensor;
            }
        }
    }

    private static void Update(IHardware hardware)
    {
        hardware.Update();
        foreach (var child in hardware.SubHardware)
        {
            Update(child);
        }
    }

    private static int ReadMemoryLoad()
    {
        var status = new MemoryStatusEx();
        if (!NativeMethods.GlobalMemoryStatusEx(ref status) || status.ullTotalPhys == 0)
        {
            return 0;
        }

        var used = status.ullTotalPhys - status.ullAvailPhys;
        return ClampPercent((float)(used * 100.0 / status.ullTotalPhys));
    }

    private static bool IsPackageTemp(string name) =>
        name.Contains("Package", StringComparison.OrdinalIgnoreCase) ||
        name.Contains("Tctl", StringComparison.OrdinalIgnoreCase) ||
        name.Contains("Tdie", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("CPU", StringComparison.OrdinalIgnoreCase);

    private static int ClampPercent(float? value)
    {
        if (value is null || float.IsNaN(value.Value))
        {
            return 0;
        }
        return Math.Clamp((int)Math.Round(value.Value), 0, 100);
    }

    private static int PositiveInt(float? value)
    {
        if (value is null || float.IsNaN(value.Value) || value <= 0)
        {
            return 0;
        }
        return (int)Math.Round(value.Value);
    }
}

readonly record struct Sample(int CpuPercent, int MemoryPercent, int CpuTempC);

readonly record struct NetCounters(long RxBytes, long TxBytes)
{
    public static NetCounters Read()
    {
        long rx = 0;
        long tx = 0;
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up ||
                nic.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            var stats = nic.GetIPv4Statistics();
            rx += stats.BytesReceived;
            tx += stats.BytesSent;
        }
        return new NetCounters(rx, tx);
    }
}

sealed record Options(string? PortName, int BaudRate, double IntervalSeconds)
{
    public static Options Parse(string[] args)
    {
        string? port = null;
        var baud = 115200;
        var interval = 1.0;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port" when i + 1 < args.Length:
                    port = args[++i];
                    break;
                case "--baud" when i + 1 < args.Length &&
                                   int.TryParse(args[++i], out var parsedBaud):
                    baud = parsedBaud;
                    break;
                case "--interval" when i + 1 < args.Length &&
                                       double.TryParse(args[++i],
                                           NumberStyles.Float,
                                           CultureInfo.InvariantCulture,
                                           out var parsedInterval):
                    interval = Math.Max(0.1, parsedInterval);
                    break;
                case "--help":
                case "-h":
                    Console.WriteLine("""
                    Usage: SysmonWindowsAgent [--port COM8] [--baud 115200] [--interval 1.0]

                    Streams CPU/MEM/TMP/RX/TX to the ESP32-S3-LCD-1.47 board.
                    The board is auto-detected by USB VID 303A unless --port is set.
                    """);
                    Environment.Exit(0);
                    break;
            }
        }

        return new Options(port, baud, interval);
    }
}

static class NativeMethods
{
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
struct MemoryStatusEx
{
    public uint dwLength;
    public uint dwMemoryLoad;
    public ulong ullTotalPhys;
    public ulong ullAvailPhys;
    public ulong ullTotalPageFile;
    public ulong ullAvailPageFile;
    public ulong ullTotalVirtual;
    public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;

    public MemoryStatusEx()
    {
        dwLength = (uint)Marshal.SizeOf<MemoryStatusEx>();
    }
}
