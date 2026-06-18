// Entry point: sample host stats once per second and stream them to the
// board over USB serial, reconnecting whenever the link drops.
import Darwin
import Foundation

let sampler = SystemSampler()

if !sampler.temperatureAvailable {
    print("temperature sensors unavailable; TMP will report 0")
}

// A write to a port whose board was just unplugged would otherwise raise
// SIGPIPE and kill the process; ignore it so writeLine can fail gracefully.
signal(SIGPIPE, SIG_IGN)

// Outer loop: (re)acquire the serial port. Inner loop: stream until a write
// fails. Both delays let an unplugged board settle before we try again.
while true {
    guard let serial = SerialPort.openFirstAvailable() else {
        print("retrying serial connection in 2 seconds")
        Thread.sleep(forTimeInterval: 2.0)
        continue
    }

    // Rate deltas (CPU, network) are meaningless across a disconnect, so drop
    // the previous baselines and let the first sample re-prime them.
    sampler.resetBaselines()

    while true {
        let line = sampler.sample().protocolLine()
        print(line)

        guard serial.writeLine(line) else {
            print("serial write failed")
            break
        }

        Thread.sleep(forTimeInterval: 1.0)
    }

    serial.close()
    print("reconnecting in 2 seconds...")
    Thread.sleep(forTimeInterval: 2.0)
}
