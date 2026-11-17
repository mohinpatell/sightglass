import SightglassCore
import SwiftUI

/// The Memory side of the panel: what is holding memory now, over the last ten
/// minutes, and which apps grew.
struct MemoryPanel: View {
    @ObservedObject var monitor: Monitor
    /// Height of the expanded "Show all" list, set by the panel to fit the screen.
    let listHeight: CGFloat
    let requestQuit: (AppUsage) -> Void
    @AppStorage("showAllMemory") private var showAll = false

    var body: some View {
        if let latest = monitor.latest, let memory = latest.memory {
            VStack(alignment: .leading, spacing: 14) {
                nowSection(latest, memory: memory)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 10 minutes").font(.headline)
                    let data = chartPoints(history: monitor.history, bucketSeconds: max(5, monitor.interval),
                                           other: "Everything else", value: { Double($0.memoryBytes) },
                                           total: { Double($0.memory?.usedBytes ?? 0) })
                    StackedChart(series: data.apps, points: data.points, scale: 1 / gigabyte, unit: " GB")
                }
                growthSection
                Text("Memory held by system processes cannot be read per app. It is part of the total.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Collecting the first sample").foregroundStyle(.secondary)
        }
    }

    private func nowSection(_ latest: Snapshot, memory: MemoryState) -> some View {
        let total = Double(memory.totalBytes)
        let parts: [(name: String, bytes: UInt64, color: Color)] = [
            ("Apps", memory.appBytes, .blue), ("Wired", memory.wiredBytes, .orange),
            ("Compressed", memory.compressedBytes, .purple),
            // Includes files macOS keeps cached, which it gives back the moment an app needs room.
            ("Available", memory.totalBytes > memory.usedBytes ? memory.totalBytes - memory.usedBytes : 0, .gray.opacity(0.5)),
        ]
        let apps = latest.apps.filter { $0.memoryBytes >= smallestListedMemory }.sorted { $0.memoryBytes > $1.memoryBytes }
        let top = Double(apps.first?.memoryBytes ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Right now").font(.headline)
                Spacer()
                Text(verbatim: "\(bytes(memory.usedBytes)) of \(bytes(memory.totalBytes))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Text(share(Double(memory.usedBytes) / total)).font(.headline).monospacedDigit()
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.name) { part in
                        Rectangle().fill(part.color).frame(width: max(0, geo.size.width * Double(part.bytes) / total - 1))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            DotLegend(items: parts.map { (name: "\($0.name) \(bytes($0.bytes))", color: $0.color) })
            HStack(spacing: 4) {
                Text("Pressure")
                Text(pressureName(memory.pressure)).fontWeight(.semibold).foregroundStyle(pressureColor(memory.pressure))
                Text(verbatim: "· \(bytes(memory.swapUsedBytes)) swapped to disk")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)

            if showAll {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(apps) { row($0, top: top, total: total) }
                    }
                }
                .frame(height: listHeight)
            } else {
                ForEach(apps.prefix(5)) { row($0, top: top, total: total) }
            }
            if apps.count > 5 {
                Button(showAll ? "Show top 5" : "Show all \(apps.count)") { showAll.toggle() }
                    .buttonStyle(.link)
            }
        }
    }

    private func row(_ app: AppUsage, top: Double, total: Double) -> some View {
        UsageRow(name: app.name, fraction: Double(app.memoryBytes) / top, value: share(Double(app.memoryBytes) / total),
                 detail: bytes(app.memoryBytes), onQuit: canQuit(app) ? { requestQuit(app) } : nil)
    }

    private func pressureName(_ pressure: MemoryState.Pressure) -> String {
        switch pressure {
        case .normal: "normal"
        case .warning: "high"
        case .critical: "critical"
        }
    }

    private func pressureColor(_ pressure: MemoryState.Pressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    private var growthSection: some View {
        let growth = memoryGrowth(history: monitor.history)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Grew the most").font(.headline)
            if growth.isEmpty {
                Text("No app has grown by 50 MB or more in the last 10 minutes").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("In the last 10 minutes. A steady climb can mean a leak.").font(.callout).foregroundStyle(.secondary)
                ForEach(growth.prefix(5), id: \.name) { item in
                    UsageRow(name: item.name, fraction: Double(item.bytes) / Double(growth[0].bytes), value: "",
                             detail: "+" + bytes(item.bytes))
                }
            }
        }
    }
}
