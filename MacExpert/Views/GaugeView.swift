import SwiftUI

struct ArcGauge: View {
    let value: Double
    let min: Double
    let max: Double
    let label: String
    let unit: String
    let format: String
    let colors: [Color]

    init(value: Double, min: Double, max: Double, label: String,
         unit: String = "", format: String = "%.0f", colors: [Color]) {
        self.value = value; self.min = min; self.max = max
        self.label = label; self.unit = unit; self.format = format
        self.colors = colors
    }

    private var norm: Double {
        let range = max - min
        guard range > 0 else { return 0 }
        return Swift.max(0, Swift.min(1, (value - min) / range))
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Background arc
                ArcPath(progress: 1.0)
                    .stroke(Color(white: 0.2), style: StrokeStyle(lineWidth: 10, lineCap: .round))

                // Colored arc
                ArcPath(progress: norm)
                    .stroke(
                        AngularGradient(
                            colors: colors,
                            center: .bottom,
                            startAngle: .degrees(-180),
                            endAngle: .degrees(0)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )

                // Glow
                ArcPath(progress: norm)
                    .stroke(
                        AngularGradient(
                            colors: colors,
                            center: .bottom,
                            startAngle: .degrees(-180),
                            endAngle: .degrees(0)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .blur(radius: 6)
                    .opacity(0.35)

                // Needle
                NeedlePath(progress: norm)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)

                // Center dot
                Circle()
                    .fill(.white.opacity(0.8))
                    .frame(width: 4, height: 4)
                    .offset(y: 16)
            }
            .frame(width: 68, height: 42)

            // Value
            Text(String(format: format, value) + unit)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            // Label
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color(white: 0.5))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13)))
    }
}

struct ArcPath: Shape {
    let progress: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY - 6)
        let radius = Swift.min(rect.width / 2, rect.height) - 8
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(180 + 180 * progress),
                    clockwise: false)
        return path
    }
}

struct NeedlePath: Shape {
    let progress: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY - 6)
        let radius = Swift.min(rect.width / 2, rect.height) - 10
        let angle = Angle.degrees(180 + 180 * progress)
        let tip = CGPoint(
            x: center.x + radius * Foundation.cos(angle.radians),
            y: center.y + radius * Foundation.sin(angle.radians)
        )
        var path = Path()
        path.move(to: center)
        path.addLine(to: tip)
        return path
    }
}

struct GaugesView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 5) {
            ArcGauge(value: vm.state.swrValue, min: 1.0, max: 3.5,
                     label: "SWR", format: "1:%.1f",
                     colors: [.green, .green, .yellow, .orange, .red])

            ArcGauge(value: vm.state.drainValue, min: 0, max: 60,
                     label: "DRAIN", unit: "A", format: "%.1f",
                     colors: [.cyan, .cyan, .cyan, .orange, .red])

            // Temp unit + scale follow the amp's TEMP/FANS setting if
            // the user has visited that sub-menu (which gives us the
            // CELSIUS/FARENHEIT marker via the RCU frame). Otherwise
            // tap the gauge to toggle C↔F manually — the choice is
            // persisted across launches via vm.cachedTempUnit.
            // Range is the same physical envelope in either unit
            // (80°C ≈ 176°F → 180°F max), so the colour stops keep
            // their relative meaning (green idle → red overheat).
            ArcGauge(value: vm.state.tempValue,
                     min: vm.cachedTempUnit == "F" ? 32  : 0,
                     max: vm.cachedTempUnit == "F" ? 180 : 80,
                     label: "TEMP",
                     unit: "\u{00B0}\(vm.cachedTempUnit)",
                     format: "%.0f",
                     colors: [.cyan, .green, .green, .orange, .red])
                .contentShape(Rectangle())
                .onTapGesture {
                    vm.cachedTempUnit = (vm.cachedTempUnit == "F") ? "C" : "F"
                }
                .help("Tap to toggle °C / °F (auto-detects from TEMP/FANS menu)")

            ArcGauge(value: vm.state.voltageValue, min: 30, max: 55,
                     label: "VOLTAGE", unit: "V", format: "%.1f",
                     colors: [.red, .orange, .green, .green, .orange, .red])
        }
    }
}
