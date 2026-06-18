// Pure data models and the rate math behind them. Kept free of system calls
// so the calculations can be unit-tested in isolation (see ModelsTests).
import Foundation

/// One second's worth of host stats, ready to send to the board.
struct StatsSample: Equatable {
    let cpu: Int
    let memory: Int
    let temperature: Int
    let rx: Int
    let tx: Int

    /// Serializes to the firmware's line protocol: integer `KEY:value` pairs.
    /// The firmware parses this exact format, so the order/keys must not change.
    func protocolLine() -> String {
        "CPU:\(cpu),MEM:\(memory),TMP:\(temperature),RX:\(rx),TX:\(tx)"
    }
}

/// Cumulative CPU time counters (in scheduler ticks) read from the kernel.
struct CPUTicks: Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    // &+ wraps instead of trapping; these are monotonic kernel counters that
    // can roll over, and a wrapped total is handled by the guards below.
    var total: UInt64 {
        user &+ system &+ idle &+ nice
    }
}

/// Cumulative network byte counters plus the time they were sampled.
struct NetworkBytes: Equatable {
    let rx: UInt64
    let tx: UInt64
    let sampledAt: TimeInterval
}

/// Network throughput in KB/s, derived from two `NetworkBytes` samples.
struct NetworkRate: Equatable {
    let rx: Int
    let tx: Int
}

/// CPU usage over the interval between two tick snapshots, as a 0–100 percent.
///
/// Returns 0 when the counters look reset or inconsistent (e.g. after a
/// reconnect) rather than producing a garbage spike.
func cpuUsagePercent(previous: CPUTicks, current: CPUTicks) -> Int {
    guard current.total >= previous.total,
          current.idle >= previous.idle else {
        return 0
    }

    let totalDelta = current.total - previous.total
    let idleDelta = current.idle - previous.idle

    guard totalDelta > 0, idleDelta <= totalDelta else {
        return 0
    }

    // Busy fraction = (total - idle) / total over the interval.
    let usedDelta = totalDelta - idleDelta
    return Int((Double(usedDelta) / Double(totalDelta) * 100).rounded())
}

/// Throughput in KB/s between two byte-counter samples.
///
/// Returns zero when no time elapsed or the counters went backwards (interface
/// reset / reconnect), avoiding divide-by-zero and bogus negative rates.
func networkRate(previous: NetworkBytes, current: NetworkBytes) -> NetworkRate {
    let elapsed = current.sampledAt - previous.sampledAt

    guard elapsed > 0,
          current.rx >= previous.rx,
          current.tx >= previous.tx else {
        return NetworkRate(rx: 0, tx: 0)
    }

    let rxPerSecond = Double(current.rx - previous.rx) / elapsed / 1024
    let txPerSecond = Double(current.tx - previous.tx) / elapsed / 1024

    return NetworkRate(
        rx: clampedInt(rxPerSecond),
        tx: clampedInt(txPerSecond)
    )
}

/// Rounds a non-negative rate to `Int`, clamping absurd values (overflow from
/// a near-zero elapsed time) to `Int.max` instead of trapping.
private func clampedInt(_ value: Double) -> Int {
    guard value.isFinite, value > 0 else {
        return 0
    }

    let rounded = value.rounded()

    guard rounded < Double(Int.max) else {
        return Int.max
    }

    return Int(rounded)
}
