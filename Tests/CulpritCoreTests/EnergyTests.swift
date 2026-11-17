import Foundation
import Testing
@testable import CulpritCore

private func battery(onBattery: Bool, percent: Int = 80, systemWatts: Double? = 20) -> BatteryState {
    BatteryState(onBattery: onBattery, percent: percent, remainingWattHours: 60, fullWattHours: 80,
                 systemWatts: systemWatts, adapterWatts: onBattery ? 0 : 60)
}

private func energySnapshot(_ t: Double, onBattery: Bool, percent: Int = 80) -> Snapshot {
    let sample = RawSample(totalCores: 2, processes: [
        ProcessUsage(pid: 1, path: "", app: "Brave Browser", cores: 0.5, watts: 3),
        ProcessUsage(pid: 2, path: "", app: "Brave Browser", cores: 0.5, watts: 1),
        ProcessUsage(pid: 3, path: "", app: "WindowServer", cores: 0.5, watts: nil),
    ], sawEveryProcess: true)
    return snapshot(from: sample, at: Date(timeIntervalSince1970: t),
                    power: ComponentPower(cpu: 6, gpu: 1, memory: 2), battery: battery(onBattery: onBattery, percent: percent))
}

@Test func unreadableCPUEnergyBecomesOneMeasuredBucket() {
    let snap = energySnapshot(0, onBattery: true)
    let watts = Dictionary(uniqueKeysWithValues: snap.apps.map { ($0.name, $0.watts) })
    #expect(watts["Brave Browser"] == 4)
    #expect(watts["WindowServer"] == 0)
    #expect(watts[systemEnergyName] == 2)  // 6 W of CPU minus the 4 W billed to Brave
    // The bucket has no CPU share, so the CPU list still starts with real apps.
    #expect(snap.apps.first?.name == "Brave Browser")
    #expect(snap.apps.last?.name == systemEnergyName)
}

@Test func breakdownAddsUpToTheWholeDraw() {
    let snap = energySnapshot(0, onBattery: true)
    #expect(snap.drawWatts == 20)
    #expect(snap.restWatts == 11)  // 20 - 6 cpu - 1 gpu - 2 memory
    let parts = Dictionary(uniqueKeysWithValues: snap.energyBreakdown.map { ($0.name, $0.watts) })
    #expect(parts == ["Brave Browser": 4, systemEnergyName: 2, graphicsName: 1, memoryName: 2, restName: 11])
    #expect(abs(parts.values.reduce(0, +) - 20) < 1e-9)
}

@Test func withoutABatteryTheDrawIsWhatTheChipReports() {
    let sample = RawSample(totalCores: 1, processes: [], sawEveryProcess: true)
    let snap = snapshot(from: sample, at: Date(), power: ComponentPower(cpu: 6, gpu: 1, memory: 2))
    #expect(snap.drawWatts == 9)
    #expect(snap.restWatts == 0)
    #expect(snapshot(from: sample, at: Date()).drawWatts == nil)
}

@Test func ledgerAccumulatesJoulesBetweenSnapshots() {
    var ledger = EnergyLedger()
    for t in [0.0, 5, 10] { ledger.add(energySnapshot(t, onBattery: true)) }
    #expect(ledger.start == Date(timeIntervalSince1970: 0))
    #expect(ledger.joules["Brave Browser"] == 40)  // 4 W for 10 s
    #expect(ledger.totalJoules == 200)             // 20 W for 10 s
    #expect(ledger.ranked.first?.name == restName)
}

@Test func ledgerStartsOverWhenUnpluggedOrPluggedIn() {
    var ledger = EnergyLedger()
    for t in [0.0, 5, 10] { ledger.add(energySnapshot(t, onBattery: false)) }
    ledger.add(energySnapshot(15, onBattery: true, percent: 77))
    #expect(ledger.onBattery)
    #expect(ledger.startPercent == 77)
    #expect(ledger.start == Date(timeIntervalSince1970: 15))
    #expect(ledger.totalJoules == 0)
    ledger.add(energySnapshot(20, onBattery: true))
    #expect(ledger.totalJoules == 100)
}

@Test func ledgerSkipsTheGapLeftBySleep() {
    var ledger = EnergyLedger()
    for t in [0.0, 5, 3600, 3605] { ledger.add(energySnapshot(t, onBattery: true)) }
    #expect(ledger.totalJoules == 200)  // two 5 second steps, the hour asleep is not counted
}

@Test func batteryRegistryIsConvertedToWattHours() throws {
    let state = try #require(batteryState(fromRegistry: [
        "CurrentCapacity": 57, "Voltage": 12000, "AppleRawCurrentCapacity": 4000, "AppleRawMaxCapacity": 7000,
        "ExternalConnected": false, "IsCharging": false, "Amperage": -1500,
        "PowerTelemetryData": ["SystemLoad": 18500],
    ]))
    #expect(state == BatteryState(onBattery: true, percent: 57, remainingWattHours: 48,
                                  fullWattHours: 84, systemWatts: 18.5, adapterWatts: 0))
    #expect(state.netWatts == -18.5)
    let noTelemetry = try #require(batteryState(fromRegistry: [
        "CurrentCapacity": 57, "Voltage": 12000, "AppleRawCurrentCapacity": 4000, "AppleRawMaxCapacity": 7000,
        "ExternalConnected": false, "Amperage": -1500,
    ]))
    #expect(noTelemetry.systemWatts == 18)  // 1.5 A at 12 V
}

@Test func chartCanStackWattsInsteadOfCores() {
    let history = [energySnapshot(100, onBattery: true), energySnapshot(101, onBattery: true)]
    let (apps, points) = chartPoints(history: history, topApps: 5, other: "Everything else",
                                     value: { $0.watts }, total: { $0.drawWatts ?? 0 })
    #expect(apps == ["Brave Browser", systemEnergyName, "Everything else"])
    #expect(points.map(\.cores) == [4, 2, 14])
}

@Test func aMacThatOutdrawsItsChargerLosesChargeWhilePluggedIn() throws {
    // Figures read from a 61 W charger feeding a busy 16 inch MacBook Pro.
    let state = try #require(batteryState(fromRegistry: [
        "CurrentCapacity": 59, "Voltage": 11775, "AppleRawCurrentCapacity": 4000, "AppleRawMaxCapacity": 6919,
        "ExternalConnected": true, "IsCharging": true,
        "PowerTelemetryData": ["SystemLoad": 59889, "SystemPowerIn": 58425],
    ]))
    #expect(!state.onBattery)
    #expect(state.adapterWatts == 58.425)
    #expect(abs(try #require(state.netWatts) + 1.464) < 1e-9)
}
