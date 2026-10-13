import SwiftUI

/// One value, driven by the Digital Crown (and −/+ buttons as a fallback),
/// the way the system's own volume and brightness controls work on watchOS.
///
/// The screen takes focus as it appears, so the crown is live without a tap
/// first; the gauge is bracketed by the same symbols the iPhone puts at the
/// ends of the matching slider, so a glance says where in the range you are
/// without reading the number.
struct WatchCrownValueView: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    /// Drawn at the low and high ends of the gauge, e.g. `sun.min`/`sun.max`.
    /// Both must be given, or neither.
    let minSymbol: String?
    let maxSymbol: String?
    let label: (Double) -> String
    let onChange: () -> Void

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var crownInput: WatchCrownInput
    /// Bumped by the −/+ buttons only: the crown makes its own haptics.
    @State private var buttonTick = 0

    init(title: LocalizedStringKey,
         systemImage: String = "slider.horizontal.3",
         value: Binding<Double>,
         range: ClosedRange<Double>,
         step: Double,
         tint: Color = .accentColor,
         minSymbol: String? = nil,
         maxSymbol: String? = nil,
         label: @escaping (Double) -> String,
         onChange: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self._value = value
        self.range = range
        self.step = step
        self.tint = tint
        self.minSymbol = minSymbol
        self.maxSymbol = maxSymbol
        self.label = label
        self.onChange = onChange
        // Start the crown where the value is: a default outside the range
        // would clamp on the first tick and slam the value to a bound.
        self._crownInput = State(initialValue: WatchCrownInput(value: value.wrappedValue, range: range, step: step))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                // The transition targets the Text itself: inside a Label it
                // has no digits to interpolate.
                Text(label(value))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.system(.title2, design: .rounded, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            gauge
            HStack(spacing: 8) {
                Button {
                    adjust(by: -step)
                } label: {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .accessibilityLabel("减少")
                .disabled(value <= range.lowerBound)
                Button {
                    adjust(by: step)
                } label: {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .accessibilityLabel("增加")
                .disabled(value >= range.upperBound)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .navigationTitle(title)
        .containerBackground(backgroundGradient, for: .navigation)
        .focusable()
        .digitalCrownRotation(crownBinding, from: range.lowerBound, through: range.upperBound, by: step,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .sensoryFeedback(.selection, trigger: buttonTick)
        .onChange(of: value) { _, newValue in
            // An echo from the phone (outside the touch window) moves the crown's
            // origin too, so the next turn continues from the real value.
            crownInput.synchronize(newValue)
        }
    }

    @ViewBuilder
    private var gauge: some View {
        if let minSymbol, let maxSymbol {
            Gauge(value: value, in: range) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            } minimumValueLabel: {
                endSymbol(minSymbol)
            } maximumValueLabel: {
                endSymbol(maxSymbol)
            }
            .gaugeStyle(.accessoryLinear)
            .tint(tint)
        } else {
            Gauge(value: value, in: range) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinear)
            .tint(tint)
        }
    }

    private func endSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    /// The value's own colour, held back so the number stays the brightest
    /// thing on the screen — and dropped almost to black in Always-On.
    private var backgroundGradient: LinearGradient {
        LinearGradient(colors: [tint.opacity(isLuminanceReduced ? 0.06 : 0.25), .black],
                       startPoint: .top, endPoint: .bottom)
    }

    /// SwiftUI writes this binding for crown input. Confirmed snapshots and
    /// button changes update state directly, so neither re-enters this setter.
    private var crownBinding: Binding<Double> {
        Binding(
            get: { crownInput.crownValue },
            set: { raw in
                guard let next = crownInput.turn(to: raw, confirmedValue: value) else { return }
                value = next
                onChange()
            }
        )
    }

    private func adjust(by delta: Double) {
        guard let next = crownInput.adjust(by: delta, confirmedValue: value) else { return }
        value = next
        buttonTick += 1
        onChange()
    }
}
