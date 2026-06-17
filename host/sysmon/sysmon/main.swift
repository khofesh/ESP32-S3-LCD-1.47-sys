//
//  main.swift
//  sysmon
//
//  Created by fahmi ahmad on 17/06/26.
//

import Foundation

struct StatsSample {
    let cpu: Int
    let memory: Int
    let temperature: Int
    let rx: Int
    let tx: Int
    
    func protocolLine() -> String {
        "CPU:\(cpu),MEM:\(memory),TMP:\(temperature),RX:\(rx),TX:\(tx)"
    }
}

let sample = StatsSample(cpu: 42, memory: 67, temperature: 58, rx: 1234, tx: 88)
print(sample.protocolLine())
