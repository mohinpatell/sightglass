import Charts
import CulpritCore
import SwiftUI

/// One line of a usage list: name, a bar, the value, and an optional second figure.
struct UsageRow: View {
    let name: String
    /// Bar length from 0 to 1.
    let fraction: Double
    let value: String
    var detail: String?
    /// When set, a quit button appears over the end of the name while the pointer is on the row.
    var onQuit: (() -> Void)?
    /// `-showQuitButtons YES` on the command line shows every quit button, for screenshots.
    @State private var hovering = UserDefaults.standard.bool(forKey: "showQuitButtons")

    var body: some View {
        HStack(spacing: 8) {
            Text(name).lineLimit(1).truncationMode(.middle)
                .frame(width: detail == nil ? 170 : 140, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if hovering, let onQuit {
                        Button(action: onQuit) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Quit \(name)")
                    }
                }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)
            Text(value).monospacedDigit().frame(width: 52, alignment: .trailing)
            if let detail {
                Text(detail).monospacedDigit().foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Two column legend. The chart's built in legend clips long names; this truncates.
struct DotLegend: View {
    let items: [(name: String, color: Color)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 3) {
            ForEach(items, id: \.name) { item in
                HStack(spacing: 5) {
                    Circle().fill(item.color).frame(width: 8, height: 8)
                    Text(item.name).font(.caption).lineLimit(1)
                }
            }
        }
    }
}

/// One color per named series, with gray kept for the trailing "everything else".
func seriesColors(count: Int) -> [Color] {
    let colors: [Color] = [.blue, .orange, .green, .purple, .pink]
    return Array(colors.prefix(max(count - 1, 0))) + [.gray.opacity(0.5)]
}

/// Stacked area chart of the last ten minutes with its legend.
struct StackedChart: View {
    let series: [String]
    let points: [ChartPoint]
    /// Each point is multiplied by this for display, and `unit` follows the axis numbers.
    let scale: Double
    let unit: String
    /// One color per series. Left out, the last series is gray and the rest get the usual colors.
    var colors: [Color]?

    var body: some View {
        let colors = colors ?? seriesColors(count: series.count)
        VStack(alignment: .leading, spacing: 6) {
            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("Value", point.cores * scale),
                    stacking: .standard
                )
                .foregroundStyle(by: .value("Series", point.app))
            }
            .chartForegroundStyleScale(domain: series, range: colors)
            .chartLegend(.hidden)
            .chartXAxis {
                // A label every 2 minutes: at most five, so they never run into each other.
                AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(verbatim: v.formatted(.number.precision(.fractionLength(0...1))) + unit)
                        }
                    }
                }
            }
            .frame(height: 150)
            DotLegend(items: Array(zip(series, colors)).map { (name: $0.0, color: $0.1) })
        }
    }
}
