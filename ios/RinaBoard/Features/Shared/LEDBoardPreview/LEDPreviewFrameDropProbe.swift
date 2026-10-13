#if DEBUG
import QuartzCore
import SwiftUI
import os

/// PR-11 item 3 measurement harness: counts how many display-link callbacks a
/// preview surface actually receives against how many the screen's own
/// refresh rate would deliver over the same span, and logs
/// delivered/expected once a second.
///
/// This answers a narrower question than "is the GPU the bottleneck" — a
/// `CADisplayLink` fires once per compositor vsync regardless of whether
/// SwiftUI had a new frame ready for it, so a shortfall here means the run
/// loop or render pipeline missed vsyncs (dropped frames), not that the GPU
/// itself was busy. It is also a simulator/device number like any other in
/// this harness: on the simulator it reflects the host Mac's display link,
/// not an iPhone's.
///
/// `#if DEBUG` only, deliberately not extended to `RINA_PERF_LOG`: a
/// `CADisplayLink` is a standing per-frame cost, so this must never compile
/// into a shape that could ship even by mistake in a `RINA_PERF_LOG` Release
/// build used for the other probes in this branch.
@Observable
final class LEDPreviewFrameDropProbe {
    /// Set once, before any probe attaches, from `-perfProbeScenario`.
    /// `nil` (the default) means no probe attaches to any preview — the
    /// harness is opt-in per launch, never on by default in a Debug build.
    static let activeLabel: String? = {
        guard let scenario = UserDefaults.standard.string(forKey: "perfProbeScenario"), !scenario.isEmpty else {
            return nil
        }
        return scenario
    }()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RinaBoard", category: "LEDPreviewFrameDropProbe")

    private let label: String
    private var link: CADisplayLink?
    private var windowStart: CFTimeInterval?
    private var delivered = 0

    init(label: String) {
        self.label = label
    }

    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        windowStart = nil
        delivered = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        guard let start = windowStart else {
            windowStart = now
            delivered = 1
            return
        }
        delivered += 1
        let elapsed = now - start
        guard elapsed >= 1.0 else { return }
        // The refresh interval of *this* callback, not a fixed constant, so
        // the "expected" side is honest about whatever cadence the display
        // link actually negotiated (e.g. a 120 Hz-capable simulator/device
        // vs. one capped lower).
        let expected = link.targetTimestamp > link.timestamp
            ? elapsed / (link.targetTimestamp - link.timestamp)
            : Double(delivered)
        Self.logger.info(
            "\(self.label, privacy: .public) delivered=\(self.delivered, privacy: .public) expected=\(String(format: "%.1f", expected), privacy: .public) overSeconds=\(String(format: "%.2f", elapsed), privacy: .public)"
        )
        windowStart = now
        delivered = 0
    }
}

/// Attaches a `LEDPreviewFrameDropProbe` to a preview surface for the
/// duration the view is on screen, active only when `-perfProbeScenario`
/// named this `label` (so several previews can each opt in independently
/// without all of them logging at once).
private struct LEDPreviewFrameDropProbeModifier: ViewModifier {
    let label: String
    @State private var probe: LEDPreviewFrameDropProbe?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard LEDPreviewFrameDropProbe.activeLabel == label else { return }
                let probe = LEDPreviewFrameDropProbe(label: label)
                probe.start()
                self.probe = probe
            }
            .onDisappear {
                probe?.stop()
                probe = nil
            }
    }
}

extension View {
    /// Opts a preview surface into the frame-drop probe under `label`. A
    /// no-op unless `-perfProbeScenario <label>` was passed at launch.
    func ledPreviewFrameDropProbe(label: String) -> some View {
        modifier(LEDPreviewFrameDropProbeModifier(label: label))
    }
}

/// `BoardPreviewRow`'s `probeLabel` is optional (most rows opt out); this
/// keeps the no-probe case a plain pass-through instead of every call site
/// having to branch.
struct OptionalProbeModifier: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.ledPreviewFrameDropProbe(label: label)
        } else {
            content
        }
    }
}
#endif
