import SwiftUI

struct PowerDisplayView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 4) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("OUTPUT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                Text("SWR: 1:\(vm.state.swr)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(swrColor)
            }

            // Power readout
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(vm.state.powerWatts)")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("W")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.gray)
                Spacer()
                // Power level indicator
                Text(levelLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.7))
            }

            // Power bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(powerGradient)
                        .frame(width: barWidth(in: geo.size.width))
                    if vm.state.powerWatts > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(powerGradient)
                            .frame(width: barWidth(in: geo.size.width))
                            .blur(radius: 5)
                            .opacity(0.35)
                    }
                }
            }
            .frame(height: 10)

            // Tick labels - auto-adjusted to current power level
            HStack {
                ForEach(tickLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color(white: 0.4))
                    if label != tickLabels.last { Spacer() }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.13)))
    }

    /// Max power for the bar / ticks. Forced to 200 W when the amp is
    /// in STANDBY but keyed (bypass mode — exciter drive only),
    /// otherwise the per-level maximum from the model.
    private var currentMaxPower: Int {
        vm.powerScaleWatts
    }

    private var levelLabel: String {
        if vm.isStandbyTX { return "STBY \(currentMaxPower)W" }
        switch vm.state.pLevel {
        case "L": return "LOW \(currentMaxPower)W"
        case "M": return "MID \(currentMaxPower)W"
        case "H": return "HIGH \(currentMaxPower)W"
        default:  return "\(currentMaxPower)W"
        }
    }

    private var tickLabels: [String] {
        let max = currentMaxPower
        let step = max / 5
        return stride(from: 0, through: max, by: step).map { w in
            w >= 1000 ? String(format: "%.1fk", Double(w) / 1000) : "\(w)"
        }
    }

    private func barWidth(in total: CGFloat) -> CGFloat {
        let pct = min(Double(vm.state.powerWatts) / Double(currentMaxPower), 1.0)
        return max(0, total * pct)
    }

    private var powerGradient: LinearGradient {
        LinearGradient(colors: [.cyan, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
    }

    private var swrColor: Color {
        let swr = vm.state.swrValue
        if swr < 1.5 { return .green }
        if swr < 2.5 { return .orange }
        return .red
    }
}
