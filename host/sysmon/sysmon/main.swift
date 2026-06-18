import Darwin
import Foundation

let sampler = SystemSampler()

if !sampler.temperatureAvailable {
    print("temperature sensors unavailable; TMP will report 0")
}

signal(SIGPIPE, SIG_IGN)

while true {
    guard let serial = SerialPort.openFirstAvailable() else {
        print("retrying serial connection in 2 seconds")
        Thread.sleep(forTimeInterval: 2.0)
        continue
    }

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
