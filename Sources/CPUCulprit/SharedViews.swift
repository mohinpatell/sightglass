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

    var body: some View {
        HStack(spacing: 8) {
            Text(name).lineLimit(1).truncationMode(.middle)
                .frame(width: detail == nil ? 170 : 140, alignment: .leading)
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

    var body: some View {
        let colors = seriesColors(count: series.count)
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
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
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
