import XCTest
@testable import sysmon

final class ModelsTests: XCTestCase {
    func testProtocolLineKeepsFirmwareFormat() {
        let sample = StatsSample(
            cpu: 42,
            memory: 67,
            temperature: 58,
            rx: 1234,
            tx: 88
        )

        XCTAssertEqual(
            sample.protocolLine(),
            "CPU:42,MEM:67,TMP:58,RX:1234,TX:88"
        )
    }

    func testCPUUsageUsesTickDeltas() {
        let previous = CPUTicks(
            user: 100,
            system: 50,
            idle: 850,
            nice: 0
        )
        let current = CPUTicks(
            user: 140,
            system: 60,
            idle: 890,
            nice: 10
        )

        XCTAssertEqual(
            cpuUsagePercent(previous: previous, current: current),
            60
        )
    }

    func testCPUCounterResetReturnsZero() {
        let previous = CPUTicks(
            user: 100,
            system: 100,
            idle: 100,
            nice: 100
        )
        let current = CPUTicks(
            user: 1,
            system: 1,
            idle: 1,
            nice: 1
        )

        XCTAssertEqual(
            cpuUsagePercent(previous: previous, current: current),
            0
        )
    }

    func testNetworkRateUsesElapsedTime() {
        let previous = NetworkBytes(
            rx: 1_000,
            tx: 2_000,
            sampledAt: 10
        )
        let current = NetworkBytes(
            rx: 3_048,
            tx: 3_024,
            sampledAt: 12
        )

        XCTAssertEqual(
            networkRate(previous: previous, current: current),
            NetworkRate(rx: 1, tx: 1)
        )
    }

    func testNetworkCounterResetReturnsZero() {
        let previous = NetworkBytes(
            rx: 5_000,
            tx: 5_000,
            sampledAt: 10
        )
        let current = NetworkBytes(
            rx: 10,
            tx: 20,
            sampledAt: 11
        )

        XCTAssertEqual(
            networkRate(previous: previous, current: current),
            NetworkRate(rx: 0, tx: 0)
        )
    }

    func testNetworkRateRejectsZeroElapsedTime() {
        let previous = NetworkBytes(
            rx: 0,
            tx: 0,
            sampledAt: 10
        )
        let current = NetworkBytes(
            rx: 1_024,
            tx: 1_024,
            sampledAt: 10
        )

        XCTAssertEqual(
            networkRate(previous: previous, current: current),
            NetworkRate(rx: 0, tx: 0)
        )
    }

    func testNetworkRateClampsIntOverflow() {
        let previous = NetworkBytes(
            rx: 0,
            tx: 0,
            sampledAt: 0
        )
        let current = NetworkBytes(
            rx: UInt64.max,
            tx: UInt64.max,
            sampledAt: 0.000_001
        )

        XCTAssertEqual(
            networkRate(previous: previous, current: current),
            NetworkRate(rx: Int.max, tx: Int.max)
        )
    }
}
