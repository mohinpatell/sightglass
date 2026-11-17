import CulpritCore
import SwiftUI

/// The Energy side of the panel: what is drawing power now, over the last ten
/// minutes, and in total since the Mac was plugged in or unplugged.
struct EnergyPanel: View {
    let monitor: Monitor
    /// Height of the expanded "Show all" list, set by the panel to fit the screen.
    let listHeight: CGFloat
    @AppStorage("showAllEnergy") private var showAll = false

    var body: some View {
        if let latest = monitor.latest, let power = latest.power, let draw = latest.drawWatts, draw > 0 {
            VStack(alignment: .leading, spacing: 14) {
                nowSection(latest, power: power, draw: draw)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 10 minutes").font(.headline)
                    let data = chartPoints(history: monitor.history, bucketSeconds: max(5, monitor.interval),
                                           other: "Everything else", value: { $0.watts }, total: { $0.drawWatts ?? 0 })
                    StackedChart(series: data.apps, points: data.points, scale: 1, unit: " W")
                }
                ledgerSection
                Text("App figures are CPU energy only. Graphics, memory and the screen cannot be split by app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(monitor.latest == nil ? "Collecting the first sample" : "This Mac does not report power readings.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Now

    private func nowSection(_ latest: Snapshot, power: ComponentPower, draw: Double) -> some View {
        let parts: [(name: String, watts: Double, color: Color)] = [
            ("CPU", power.cpu, .blue), (graphicsName, power.gpu, .green),
            (memoryName, power.memory, .purple), ("Screen and rest", latest.restWatts, .gray.opacity(0.5)),
        ]
        let apps = latest.apps.filter { $0.watts >= 0.0005 }.sorted { $0.watts > $1.watts }
        let top = apps.first?.watts ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Right now").font(.headline)
                Spacer()
                if let battery = latest.battery {
                    Text(status(battery, draw: draw)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(watts(draw)).font(.headline).monospacedDigit()
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.name) { part in
                        Rectangle().fill(part.color).frame(width: max(0, geo.size.width * part.watts / draw - 1))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            DotLegend(items: parts.map { (name: "\($0.name) \(watts($0.watts))", color: $0.color) })
            if let battery = latest.battery, let net = battery.netWatts, let adapter = battery.adapterWatts {
                flowRow(battery, coming: adapter, going: draw, net: net)
            }
            Spacer().frame(height: 2)

            if showAll {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(apps) { row($0, top: top, draw: draw) }
                    }
                }
                .frame(height: listHeight)
            } else {
                ForEach(apps.prefix(5)) { row($0, top: top, draw: draw) }
            }
            if apps.count > 5 {
                Button(showAll ? "Show top 5" : "Show all \(apps.count)") { showAll.toggle() }
                    .buttonStyle(.link)
            }
        }
    }

    private func row(_ app: AppUsage, top: Double, draw: Double) -> some View {
        UsageRow(name: app.name, fraction: app.watts / top, value: share(app.watts / draw), detail: watts(app.watts))
    }

    private func status(_ battery: BatteryState, draw: Double) -> String {
        "\(battery.onBattery ? "on battery" : "plugged in"), \(battery.percent)%"
    }

    /// Power coming in, power going out, and the difference, which is what the
    /// battery gains or loses. Plugged in does not always mean gaining.
    private func flowRow(_ battery: BatteryState, coming: Double, going: Double, net: Double) -> some View {
        let steady = abs(net) < 0.05
        let hours = net > 0 ? (battery.fullWattHours - battery.remainingWattHours) / net
                            : battery.remainingWattHours / -net
        return HStack(alignment: .top) {
            flowColumn("Coming in", coming > 0 ? watts(coming) : "0 W", note: battery.onBattery ? "no charger" : "from charger")
            Spacer()
            flowColumn("Going out", watts(going), note: "used by the Mac")
            Spacer()
            flowColumn(steady ? "Battery" : net > 0 ? "Battery gaining" : "Battery losing",
                       steady ? "steady" : (net > 0 ? "+" : "\u{2212}") + watts(abs(net)),
                       note: steady ? "" : "\(net > 0 ? "full" : "empty") in about \(duration(hours * 3600))")
                .foregroundStyle(steady ? Color.primary : net > 0 ? Color.green : Color.orange)
        }
        .padding(.top, 4)
    }

    private func flowColumn(_ title: String, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Since plugged in or unplugged

    private var ledgerSection: some View {
        let ledger = monitor.ledger
        let total = ledger.totalJoules
        let ranked = ledger.ranked
        return VStack(alignment: .leading, spacing: 6) {
            Text(ledger.onBattery ? "Since unplugged" : "Since plugged in").font(.headline)
            if total > 0, let start = ledger.start, let now = monitor.latest?.time {
                Text(summary(ledger, total: total, elapsed: now.timeIntervalSince(start)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ForEach(ranked.prefix(6), id: \.name) { item in
                    UsageRow(name: item.name, fraction: item.joules / (ranked.first?.joules ?? 1),
                             value: share(item.joules / total), detail: wattHours(joules: item.joules))
                }
            } else {
                Text("Nothing recorded yet").foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ ledger: EnergyLedger, total: Double, elapsed: TimeInterval) -> String {
        var text = "\(duration(elapsed)) awake, \(wattHours(joules: total)) used"
        if ledger.onBattery, let from = ledger.startPercent, let to = monitor.latest?.battery?.percent {
            text += ", battery \(from)% to \(to)%"
        }
        return text
    }
}
