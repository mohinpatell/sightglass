import CulpritCore
import Foundation

// Usage: culprit [samples]   Prints the busiest apps once a second.
let limit = CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? Int.max
let sampler = Sampler()
_ = sampler.sample()

for _ in 0..<limit {
    sleep(1)
    guard let sample = sampler.sample() else { continue }
    let snap = snapshot(from: sample, at: Date())
    let top = snap.apps.prefix(5).map { String(format: "%@ %.0f%%", $0.name, $0.cores * 100) }
    print(String(format: "total %4.0f%%  ", snap.totalCores * 100) + top.joined(separator: "  "))
    fflush(stdout)
}
