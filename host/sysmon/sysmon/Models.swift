import Foundation

struct StatsSample: Equatable {
    let cpu: Int
    let memory: Int
    let temperature: Int
    let rx: Int
    let tx: Int

    func protocolLine() -> String {
        "CPU:\(cpu),MEM:\(memory),TMP:\(temperature),RX:\(rx),TX:\(tx)"
    }
}

struct CPUTicks: Equatable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 {
        user &+ system &+ idle &+ nice
    }
}

struct NetworkBytes: Equatable {
    let rx: UInt64
    let tx: UInt64
    let sampledAt: TimeInterval
}

struct NetworkRate: Equatable {
    let rx: Int
    let tx: Int
}

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

    let usedDelta = totalDelta - idleDelta
    return Int((Double(usedDelta) / Double(totalDelta) * 100).rounded())
}

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
