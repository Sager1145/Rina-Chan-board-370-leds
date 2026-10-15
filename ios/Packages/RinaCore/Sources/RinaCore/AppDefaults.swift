import Foundation

/// Decoded `scroll_text_defaults.json`.
public struct ScrollTextDefaults: Codable, Sendable, Equatable {
    public let defaultText: String
    public let maxChars: Int
    public let maxBytes: Int
    public let fpsDefault: Int
    public let fpsMin: Int
    public let fpsMax: Int
    public let fpsPresets: [Int]
    public let brightnessPresets: [Int]
    public let autoIntervalPresetsMs: [Int]
    public let fontId: String
    public let generatorVersion: String

    public static let fallback = ScrollTextDefaults(
        defaultText: "RinaChanBoard 370 LED こんにちは 璃奈ちゃんボード",
        maxChars: 1000,
        maxBytes: 4096,
        fpsDefault: 10,
        fpsMin: 1,
        fpsMax: 60,
        fpsPresets: [1, 10, 20, 30, 40, 50, 60],
        brightnessPresets: [10, 25, 50, 80, 128, 160, 200],
        autoIntervalPresetsMs: [500, 1000, 2000, 3000, 5000, 7500, 10000],
        fontId: "ark_pixel_12px_fusion_bitmap_v4",
        generatorVersion: "webui-scrollgen-6.4.2"
    )
}
