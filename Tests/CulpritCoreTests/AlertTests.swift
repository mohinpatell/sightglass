import Foundation
import Testing
@testable import CulpritCore

private func snap(_ t: Double, apps: [AppUsage] = [], battery: BatteryState? = nil, memory: MemoryState? = nil) -> Snapshot {
    Snapshot(time: Date(timeIntervalSince1970: t), totalCores: apps.reduce(0) { $0 + $1.cores }, apps: apps,
             battery: battery, memory: memory)
}

private func battery(onBattery: Bool, draw: Double, adapter: Double, remaining: Double = 40) -> BatteryState {
    BatteryState(onBattery: onBattery, percent: 60, remainingWattHours: remaining, fullWattHours: 80,
                 systemWatts: draw, adapterWatts: onBattery ? 0 : adapter)
}

private func memory(_ pressure: MemoryState.Pressure) -> MemoryState {
    MemoryState(totalBytes: 36 << 30, appBytes: 28 << 30, wiredBytes: 3 << 30, compressedBytes: 2 << 30,
                swapUsedBytes: 4 << 30, pressure: pressure)
}

/// Feeds one snapshot every 5 seconds from `start` up to and including `end`.
private func feed(_ engine: inout AlertEngine, from start: Double = 0, to end: Double, _ make: (Double) -> Snapshot) -> [Alert] {
    stride(from: start, through: end, by: 5).flatMap { engine.ingest(make($0)) }
}

@Test func nothingFiresUnlessItIsSwitchedOn() {
    var engine = AlertEngine()
    let alerts = feed(&engine, to: 900) {
        snap($0, apps: [AppUsage(name: "node", cores: 3)], battery: battery(onBattery: false, draw: 70, adapter: 58),
             memory: memory(.critical))
    }
    #expect(alerts.isEmpty)
}

@Test func anAppOverACoreForFiveMinutesNotifiesOnceAnHour() {
    var engine = AlertEngine()
    engine.enabled = [.cpuHog]
    let hog = { (t: Double) in snap(t, apps: [AppUsage(name: "Python train.py", cores: 2.4), AppUsage(name: "Finder", cores: 0.1)]) }
    #expect(feed(&engine, to: 295, hog).isEmpty)
    let alerts = feed(&engine, from: 300, to: 3000, hog)
    #expect(alerts.count == 1)
    #expect(alerts[0].title == "Python train.py is hogging the CPU")
    #expect(alerts[0].body.contains("2.4 cores") && alerts[0].body.contains("5 minutes"))
    // Still hogging more than an hour after the first alert: remind once.
    #expect(feed(&engine, from: 3005, to: 4000, hog).count == 1)
}

@Test func aShortDipKeepsTheHogClockButALongOneRestartsIt() {
    var engine = AlertEngine()
    engine.enabled = [.cpuHog]
    let hog = { (t: Double) in snap(t, apps: [AppUsage(name: "node", cores: 1.5)]) }
    let idle = { (t: Double) in snap(t, apps: [AppUsage(name: "node", cores: 0.2)]) }
    #expect(feed(&engine, to: 200, hog).isEmpty)
    #expect(feed(&engine, from: 205, to: 215, idle).isEmpty)      // 10 second dip
    #expect(feed(&engine, from: 220, to: 300, hog).count == 1)    // clock kept running from 0

    var second = AlertEngine()
    second.enabled = [.cpuHog]
    #expect(feed(&second, to: 200, hog).isEmpty)
    #expect(feed(&second, from: 205, to: 260, idle).isEmpty)      // a minute of calm
    #expect(feed(&second, from: 265, to: 500, hog).isEmpty)       // clock restarted at 265
    #expect(feed(&second, from: 505, to: 570, hog).count == 1)
}

@Test func leftoverBucketsNeverCountAsAHog() {
    var engine = AlertEngine()
    engine.enabled = [.cpuHog]
    #expect(feed(&engine, to: 900) { snap($0, apps: [AppUsage(name: shortLivedName, cores: 3)]) }.isEmpty)
}

@Test func losingChargeWhilePluggedInNotifiesAfterTwoMinutes() {
    var engine = AlertEngine()
    engine.enabled = [.losingWhilePlugged]
    let losing = { (t: Double) in
        snap(t, apps: [AppUsage(name: "Python synth_cosy.py", cores: 2, watts: 9)], battery: battery(onBattery: false, draw: 72, adapter: 58))
    }
    #expect(feed(&engine, to: 115, losing).isEmpty)
    let alerts = feed(&engine, from: 120, to: 600, losing)
    #expect(alerts.count == 1)
    #expect(alerts[0].body == "The charger supplies 58 W and the Mac is using 72 W, so the battery is losing 14 W. Biggest user: Python synth_cosy.py at 9.0 W.")
}

@Test func gainingChargeOrBeingOnBatteryIsNotLosingWhilePlugged() {
    var engine = AlertEngine()
    engine.enabled = [.losingWhilePlugged]
    #expect(feed(&engine, to: 600) { snap($0, battery: battery(onBattery: false, draw: 30, adapter: 58)) }.isEmpty)
    #expect(feed(&engine, from: 605, to: 1200) { snap($0, battery: battery(onBattery: true, draw: 30, adapter: 0)) }.isEmpty)
}

@Test func memoryPressureNotifiesAfterHalfAMinuteAndNamesTheBiggestApp() {
    var engine = AlertEngine()
    engine.enabled = [.memoryPressure]
    let apps = [AppUsage(name: "Brave Browser", cores: 0.2, memoryBytes: 10 << 30), AppUsage(name: "node", cores: 1, memoryBytes: 2 << 30)]
    #expect(feed(&engine, to: 600) { snap($0, apps: apps, memory: memory(.normal)) }.isEmpty)
    let alerts = feed(&engine, from: 605, to: 900) { snap($0, apps: apps, memory: memory(.warning)) }
    #expect(alerts.count == 1)
    #expect(alerts[0].body == "Using 33.0 of 36 GB, with 4.0 GB swapped to disk. Biggest: Brave Browser at 10.0 GB.")
}

@Test func lowBatteryNotifiesOncePerUnpluggedStretch() {
    var engine = AlertEngine()
    engine.enabled = [.batteryLow]
    let low = { (t: Double) in snap(t, battery: battery(onBattery: true, draw: 33, adapter: 0, remaining: 30)) }
    #expect(feed(&engine, to: 55, low).isEmpty)
    #expect(feed(&engine, from: 60, to: 5000, low).count == 1)
    // Plenty left is fine, and plugging in then unplugging allows a new alert.
    #expect(feed(&engine, from: 5005, to: 5100) { snap($0, battery: battery(onBattery: false, draw: 33, adapter: 58)) }.isEmpty)
    #expect(feed(&engine, from: 5105, to: 5300, low).count == 1)
    var other = AlertEngine()
    other.enabled = [.batteryLow]
    #expect(feed(&other, to: 600) { snap($0, battery: battery(onBattery: true, draw: 10, adapter: 0, remaining: 40)) }.isEmpty)
}

// MARK: Memory and quitting

@Test func snapshotCarriesMemoryAndListsIdleAppsOnlyWhenTheyAreBig() {
    let sample = RawSample(totalCores: 1, processes: [ProcessUsage(pid: 1, path: "", app: "node", cores: 1, watts: 2)],
                           sawEveryProcess: true,
                           memory: ["node": 300 << 20, "Brave Browser": 4 << 30, "tinyhelper": 2 << 20],
                           pids: ["node": [1], "Brave Browser": [7, 8]])
    let snap = snapshot(from: sample, at: Date())
    #expect(snap.apps.map(\.name) == ["node", "Brave Browser"])
    #expect(snap.apps[1] == AppUsage(name: "Brave Browser", cores: 0, watts: 0, memoryBytes: 4 << 30, pids: [7, 8]))
    #expect(snap.apps[0].memoryBytes == 300 << 20)
}

@Test func memoryGrowthRanksAppsThatGrewAndIgnoresNewOnes() {
    func at(_ t: Double, _ apps: [(String, UInt64)]) -> Snapshot {
        snap(t, apps: apps.map { AppUsage(name: $0.0, cores: 0, memoryBytes: $0.1 << 20) })
    }
    let history = [at(0, [("Brave Browser", 4000), ("node", 500), ("Finder", 200)]),
                   at(300, [("Brave Browser", 4100), ("node", 900), ("Finder", 210)]),
                   at(600, [("Brave Browser", 4300), ("node", 1700), ("Finder", 190), ("Xcode", 3000)])]
    let growth = memoryGrowth(history: history)
    #expect(growth.map(\.name) == ["node", "Brave Browser"])
    #expect(growth[0].bytes == 1200 << 20)
    #expect(memoryGrowth(history: [history[0]]).isEmpty)
}

@Test func signalStopsAProcessOfOurOwn() throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sleep")
    task.arguments = ["60"]
    try task.run()
    #expect(signal(pids: [task.processIdentifier], force: false) == 1)
    task.waitUntilExit()
    #expect(task.terminationReason == .uncaughtSignal)
    // launchd belongs to root, so the signal is refused. Pid 1 is never even tried.
    #expect(signal(pids: [1], force: true) == 0)
}

@Test func livePowerFiguresReplaceTheStaleOnes() {
    let stale = battery(onBattery: false, draw: 60, adapter: 58)
    let fresh = stale.replacingPower(systemWatts: 33, adapterWatts: 40)
    #expect(fresh.netWatts == 7)
    #expect(fresh.percent == stale.percent)
    // On battery nothing is coming in, whatever the controller still reports.
    #expect(battery(onBattery: true, draw: 30, adapter: 0).replacingPower(systemWatts: 33, adapterWatts: 5).netWatts == -33)
}
