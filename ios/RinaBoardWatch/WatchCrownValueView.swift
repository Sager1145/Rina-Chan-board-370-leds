import SwiftUI

/// One value, driven by the Digital Crown (and −/+ buttons as a fallback),
/// the way the system's own volume and brightness controls work on watchOS.
struct WatchCrownValueView: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String
    let onChange: () -> Void

    @State private var crownValue: Double

    init(title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
         label: @escaping (Double) -> String, onChange: @escaping () -> Void) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.label = label
        self.onChange = onChange
        // Start the crown where the value is: a default outside the range
        // would clamp on the first tick and slam the value to a bound.
        self._crownValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(label(value))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Gauge(value: value, in: range) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinear)
            .tint(.accentColor)
            HStack {
                Button {
                    adjust(by: -step)
                } label: {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("减少")
                Button {
                    adjust(by: step)
                } label: {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("增加")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .navigationTitle(title)
        .focusable()
        .digitalCrownRotation($crownValue, from: range.lowerBound, through: range.upperBound, by: step,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownValue) { _, newValue in
            let snapped = snap(newValue)
            guard snapped != value else { return }
            value = snapped
            onChange()
        }
        .onChange(of: value) { _, newValue in
            // An echo from the phone (outside the touch window) moves the crown's
            // origin too, so the next turn continues from the real value.
            if abs(newValue - crownValue) >= step { crownValue = newValue }
        }
    }

    private func adjust(by delta: Double) {
        let next = snap(value + delta)
        guard next != value else { return }
        value = next
        crownValue = next
        onChange()
    }

    private func snap(_ raw: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, raw))
        let steps = ((clamped - range.lowerBound) / step).rounded()
        return min(range.upperBound, range.lowerBound + steps * step)
    }
}
