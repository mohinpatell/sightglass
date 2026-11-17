import SightglassCore
import Foundation

// Usage: sightglass-probe [samples]            Prints the busiest apps once a second.
//        sightglass-probe --energy [samples]   Prints power readings and the apps using the most energy.
var arguments = Array(CommandLine.arguments.dropFirst())
let energy = arguments.first == "--energy"
if energy { arguments.removeFirst() }
let limit = arguments.first.flatMap { Int($0) } ?? Int.max
let sampler = Sampler()
let power = PowerReader()
_ = sampler.sample()
_ = power?.sample()

for _ in 0..<limit {
    sleep(1)
    let components = power?.sample()
    guard let sample = sampler.sample() else { continue }
    if energy {
        let measured = sample.processes.filter { $0.watts != nil }
        let battery = readBattery()
        print(String(format: "system %@ W  cpu %.2f W  gpu %.2f W  memory %.2f W  |  readable processes: %.2f W for %.0f%% of cpu time",
                     battery?.systemWatts.map { String(format: "%.1f", $0) } ?? "?",
                     components?.cpu ?? .nan, components?.gpu ?? .nan, components?.memory ?? .nan,
                     measured.reduce(0) { $0 + ($1.watts ?? 0) },
                     measured.reduce(0) { $0 + $1.cores } / sample.totalCores * 100))
        let top = measured.sorted { $0.watts! > $1.watts! }.prefix(4)
        print("   " + top.map { String(format: "%@ %.0f mW (%.0f%% of a core)", $0.app, $0.watts! * 1000, $0.cores * 100) }.joined(separator: "  "))
    } else {
        let snap = snapshot(from: sample, at: Date())
        let top = snap.apps.prefix(5).map { String(format: "%@ %.0f%%", $0.name, $0.cores * 100) }
        print(String(format: "total %4.0f%%  ", snap.totalCores * 100) + top.joined(separator: "  "))
    }
    fflush(stdout)
}
