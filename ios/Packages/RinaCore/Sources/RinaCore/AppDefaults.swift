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

/// The subset of `webui_config.json` the app needs: brightness/autoInterval/
/// scroll ranges & presets, firmware upload/queue pacing, and preview sizing
/// constants.
public struct AppDefaults: Codable, Sendable, Equatable {
    public struct BrightnessConfig: Codable, Sendable, Equatable {
        public let minBrightness: Int
        public let maxBrightness: Int
        public let defaultBrightness: Int
        public let fullBrightness: Int
        public let powerWarningWatts: Double
        public let estimatedWattsPerChannel: Double
        public let channelCount: Int
        public let defaultColor: String
    }

    public struct AutoIntervalConfig: Codable, Sendable, Equatable {
        public let minMs: Int
        public let maxMs: Int
        public let buttonStepMs: Int
        public let presetsMs: [Int]
    }

    public struct ScrollConfig: Codable, Sendable, Equatable {
        public let fpsMin: Int
        public let fpsMax: Int
        public let defaultFps: Int
        public let fpsPresets: [Int]
        public let uploadChunkFrames: Int
        public let maxTextChars: Int
        public let firmwareMaxFramesDefault: Int
    }

    public struct FirmwareQueuesConfig: Codable, Sendable, Equatable {
        /// Between-frame pump interval (ms).
        public let frameSendIntervalMs: Int
        public let frameQueueMax: Int
        /// Between-button-press pump interval (ms).
        public let buttonCommandIntervalMs: Int
        public let buttonCommandQueueMax: Int
        public let scrollButtonStopFullSyncDelayMs: Int
    }

    public struct PreviewSizeConfig: Codable, Sendable, Equatable {
        public let defaultCell: Int
        public let minCell: Int
        public let maxCell: Int
        public let edgeGap: Int
        public let minWidth: Int
        public let maxHeight: Int
    }

    public let brightness: BrightnessConfig
    public let autoInterval: AutoIntervalConfig
    public let scroll: ScrollConfig
    public let firmwareQueues: FirmwareQueuesConfig
    public let previewSize: PreviewSizeConfig

    /// Hard-coded fallback matching `webui_config.json` so the app still
    /// functions if the resource bundle is missing/corrupt.
    public static let fallback = AppDefaults(
        brightness: BrightnessConfig(
            minBrightness: 10,
            maxBrightness: 200,
            defaultBrightness: 50,
            fullBrightness: 255,
            powerWarningWatts: 40,
            estimatedWattsPerChannel: 0.06,
            channelCount: 5,
            defaultColor: "#ec3fc7"
        ),
        autoInterval: AutoIntervalConfig(
            minMs: 500,
            maxMs: 10000,
            buttonStepMs: 500,
            presetsMs: [500, 1000, 2000, 3000, 5000, 7500, 10000]
        ),
        scroll: ScrollConfig(
            fpsMin: 1,
            fpsMax: 60,
            defaultFps: 10,
            fpsPresets: [1, 10, 20, 30, 40, 50, 60],
            uploadChunkFrames: 24,
            maxTextChars: 1000,
            firmwareMaxFramesDefault: 3072
        ),
        firmwareQueues: FirmwareQueuesConfig(
            frameSendIntervalMs: 20,
            frameQueueMax: 6,
            buttonCommandIntervalMs: 120,
            buttonCommandQueueMax: 4,
            scrollButtonStopFullSyncDelayMs: 140
        ),
        previewSize: PreviewSizeConfig(
            defaultCell: 18,
            minCell: 5,
            maxCell: 62,
            edgeGap: 12,
            minWidth: 320,
            maxHeight: 650
        )
    )

    /// Decodes from the full `webui_config.json` document, plucking only the
    /// keys this struct needs.
    public init(webuiConfigJSON data: Data) throws {
        let decoder = JSONDecoder()
        let raw = try decoder.decode(RawWebUIConfig.self, from: data)
        self.init(
            brightness: BrightnessConfig(
                minBrightness: raw.led.minBrightness,
                maxBrightness: raw.led.maxBrightness,
                defaultBrightness: raw.led.defaultBrightness,
                fullBrightness: raw.led.fullBrightness,
                powerWarningWatts: raw.led.powerWarningWatts,
                estimatedWattsPerChannel: raw.led.estimatedWattsPerChannel,
                channelCount: raw.led.channelCount,
                defaultColor: raw.led.defaultColor
            ),
            autoInterval: AutoIntervalConfig(
                minMs: raw.autoInterval.minMs,
                maxMs: raw.autoInterval.maxMs,
                buttonStepMs: raw.autoInterval.buttonStepMs,
                presetsMs: raw.autoInterval.presetsMs
            ),
            scroll: ScrollConfig(
                fpsMin: raw.scroll.fpsMin,
                fpsMax: raw.scroll.fpsMax,
                defaultFps: raw.scroll.defaultFps,
                fpsPresets: raw.scroll.fpsPresets,
                uploadChunkFrames: raw.scroll.uploadChunkFrames,
                maxTextChars: raw.scroll.maxTextChars,
                firmwareMaxFramesDefault: raw.scroll.firmwareMaxFramesDefault
            ),
            firmwareQueues: FirmwareQueuesConfig(
                frameSendIntervalMs: raw.firmwareQueues.frameSendIntervalMs,
                frameQueueMax: raw.firmwareQueues.frameQueueMax,
                buttonCommandIntervalMs: raw.firmwareQueues.buttonCommandIntervalMs,
                buttonCommandQueueMax: raw.firmwareQueues.buttonCommandQueueMax,
                scrollButtonStopFullSyncDelayMs: raw.firmwareQueues.scrollButtonStopFullSyncDelayMs
            ),
            previewSize: PreviewSizeConfig(
                defaultCell: raw.led.previewSize.defaultCell,
                minCell: raw.led.previewSize.minCell,
                maxCell: raw.led.previewSize.maxCell,
                edgeGap: raw.led.previewSize.edgeGap,
                minWidth: raw.led.previewSize.minWidth,
                maxHeight: raw.led.previewSize.maxHeight
            )
        )
    }

    public init(brightness: BrightnessConfig, autoInterval: AutoIntervalConfig, scroll: ScrollConfig,
                firmwareQueues: FirmwareQueuesConfig, previewSize: PreviewSizeConfig) {
        self.brightness = brightness
        self.autoInterval = autoInterval
        self.scroll = scroll
        self.firmwareQueues = firmwareQueues
        self.previewSize = previewSize
    }

    // MARK: - Raw `webui_config.json` decoding shape

    struct RawWebUIConfig: Codable {
        struct Led: Codable {
            let minBrightness: Int
            let maxBrightness: Int
            let defaultBrightness: Int
            let fullBrightness: Int
            let powerWarningWatts: Double
            let estimatedWattsPerChannel: Double
            let channelCount: Int
            let defaultColor: String
            let previewSize: PreviewSize

            struct PreviewSize: Codable {
                let defaultCell: Int
                let minCell: Int
                let maxCell: Int
                let edgeGap: Int
                let minWidth: Int
                let maxHeight: Int
            }
        }

        struct AutoInterval: Codable {
            let minMs: Int
            let maxMs: Int
            let buttonStepMs: Int
            let presetsMs: [Int]
        }

        struct Scroll: Codable {
            let fpsMin: Int
            let fpsMax: Int
            let defaultFps: Int
            let fpsPresets: [Int]
            let uploadChunkFrames: Int
            let maxTextChars: Int
            let firmwareMaxFramesDefault: Int
        }

        struct FirmwareQueues: Codable {
            let frameSendIntervalMs: Int
            let frameQueueMax: Int
            let buttonCommandIntervalMs: Int
            let buttonCommandQueueMax: Int
            let scrollButtonStopFullSyncDelayMs: Int
        }

        let led: Led
        let autoInterval: AutoInterval
        let scroll: Scroll
        let firmwareQueues: FirmwareQueues
    }
}
