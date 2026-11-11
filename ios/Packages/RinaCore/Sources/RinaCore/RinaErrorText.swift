import Foundation

/// The one place that turns any thrown error into text a person can read.
///
/// Strings are Simplified Chinese literals looked up in the app's main bundle
/// (the same way `RinaTransportError` is localized), so the literal is the
/// catalog key. Everything here is pure and nonisolated: call it from any
/// actor.
public enum RinaErrorText {
    // MARK: - Any error

    /// A specific, localized message for `error`. Never empty, and never the
    /// system's "The operation couldn't be completed (… error N)" for an
    /// error type that carries no description of its own.
    public static func message(for error: any Error) -> String {
        if let linkError = error as? RinaLinkError {
            return boardMessage(linkError.error, code: linkError.code)
        }
        // Before the `LocalizedError` check: Foundation gives these two a
        // generic description that hides which field was wrong.
        if let decodingError = error as? DecodingError {
            return decodingMessage(decodingError)
        }
        if error is CancellationError {
            return NSLocalizedString("操作已取消", comment: "transport error cancelled")
        }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        // A Swift error with no Objective-C identity bridges to an NSError
        // whose domain is its own type name, and whose description is the
        // generic sentence. Anything else (URLError, POSIXError, CocoaError,
        // CoreBluetooth, AVFoundation, a plain NSError …) comes from a system
        // framework that already localized its description.
        let bridged = error as NSError
        if bridged.domain != String(reflecting: type(of: error)) {
            let description = bridged.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty { return description }
        }
        return String(
            format: NSLocalizedString("发生未知错误：%@", comment: "generic error; argument is the raw error value"),
            String(describing: error)
        )
    }

    // MARK: - Board-reported errors

    /// A localized message for an error text the board sent, either in an
    /// error frame (`RinaLinkError.error` + `code`) or as the `"error"` field
    /// of an `ok:false` command reply (pass `code: nil`).
    ///
    /// Known firmware texts map to their own message. Any other text falls
    /// back to a sentence chosen by status code, with the board's original
    /// text and code appended so nothing is hidden.
    public static func boardMessage(_ text: String?, code: Int?) -> String {
        let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let known = knownBoardMessage(raw) {
            return known
        }
        guard !raw.isEmpty || code != nil else {
            return NSLocalizedString("面板返回了未知错误", comment: "board error with neither text nor code")
        }
        let head = boardFallbackHead(code: code)
        switch (code, raw.isEmpty) {
        case (let code?, false):
            return String(
                format: NSLocalizedString("%1$@（%2$lld）：%3$@", comment: "board error: summary, status code, board's original text"),
                head, code, raw
            )
        case (let code?, true):
            return String(
                format: NSLocalizedString("%1$@（%2$lld）", comment: "board error: summary, status code"),
                head, code
            )
        default:
            return String(
                format: NSLocalizedString("%1$@：%2$@", comment: "board error: summary, board's original text"),
                head, raw
            )
        }
    }

    /// Whether `text` is a firmware error text with its own localized message.
    public static func isKnownBoardText(_ text: String?) -> Bool {
        let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && knownBoardMessage(raw) != nil
    }

    private static func boardFallbackHead(code: Int?) -> String {
        switch code {
        case 400?:
            return NSLocalizedString("面板拒绝了请求", comment: "board error class 400")
        case 404?:
            return NSLocalizedString("面板上找不到请求的内容", comment: "board error class 404")
        case 409?:
            return NSLocalizedString("面板状态已变化，请刷新后重试", comment: "board error class 409")
        case 413?:
            return NSLocalizedString("发送的内容超出面板限制", comment: "board error class 413")
        case 500?:
            return NSLocalizedString("面板内部错误", comment: "board error class 500")
        case 503?:
            return NSLocalizedString("面板暂时无法处理请求", comment: "board error class 503")
        case 507?:
            return NSLocalizedString("面板内存不足", comment: "board error class 507")
        default:
            return NSLocalizedString("面板返回了错误", comment: "board error with an unrecognized or missing status code")
        }
    }

    private static func knownBoardMessage(_ raw: String) -> String? {
        for rule in boardRules {
            for match in rule.matches {
                if let detail = match.detail(in: raw) {
                    return rule.message(detail.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return nil
    }

    // MARK: - Firmware text table

    /// One firmware error text (or family of texts) and its message.
    struct BoardRule: Sendable {
        enum Match: Sendable {
            /// The whole text.
            case exact(String)
            /// Text starts with this; `detail` is what follows.
            case starts(String)
            /// Text ends with this; `detail` is what precedes.
            case ends(String)
            /// Text contains this; `detail` is what follows.
            case contains(String)

            func detail(in raw: String) -> String? {
                switch self {
                case .exact(let text):
                    return raw == text ? "" : nil
                case .starts(let text):
                    return raw.hasPrefix(text) ? String(raw.dropFirst(text.count)) : nil
                case .ends(let text):
                    return raw.hasSuffix(text) ? String(raw.dropLast(text.count)) : nil
                case .contains(let text):
                    guard let range = raw.range(of: text) else { return nil }
                    return String(raw[range.upperBound...])
                }
            }
        }

        let matches: [Match]
        let message: @Sendable (_ detail: String) -> String

        init(_ matches: Match..., message: @escaping @Sendable (_ detail: String) -> String) {
            self.matches = matches
            self.message = message
        }
    }

    /// The digits `detail` starts with ("24 bytes)" -> "24"), or `detail`
    /// itself when it does not start with a digit.
    private static func leadingNumber(_ detail: String) -> String {
        let digits = detail.prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? detail : String(digits)
    }

    /// Every error text the firmware sends that a person can plausibly hit
    /// (`esp32s3_firmware/src/protocol.cpp`, `storage.cpp`, `led_renderer.cpp`,
    /// `transport_ble.cpp`). First match wins. To cover a new text, add a rule.
    static let boardRules: [BoardRule] = [
        // Commands and framing
        BoardRule(.starts("unknown command: ")) { detail in
            String(format: NSLocalizedString("面板不支持指令 %@，请更新面板固件", comment: "board error: unknown command name"), detail)
        },
        BoardRule(.exact("unknown blob kind"), .starts("unknown message type: ")) { _ in
            NSLocalizedString("面板不支持这项功能，请更新面板固件", comment: "board error: unknown blob kind or message type")
        },
        BoardRule(.starts("invalid JSON: "), .exact("invalid BLOB_BEGIN JSON")) { detail in
            detail.isEmpty
                ? NSLocalizedString("面板无法解析收到的数据", comment: "board error: invalid JSON")
                : String(format: NSLocalizedString("面板无法解析收到的数据：%@", comment: "board error: invalid JSON with parser detail"), detail)
        },
        BoardRule(.exact("inbound overflow")) { _ in
            NSLocalizedString("发送过快，面板来不及处理，请稍后重试", comment: "board error: inbound overflow")
        },
        BoardRule(.exact("frame payload too large")) { _ in
            NSLocalizedString("单次发送的数据过大，面板无法接收", comment: "board error: frame payload too large")
        },
        BoardRule(.exact("JSON response exceeds capacity")) { _ in
            NSLocalizedString("面板的回复内容过大，无法发送", comment: "board error: JSON response exceeds capacity")
        },

        // Wi-Fi, hotspot, mode
        BoardRule(.exact("failed to start wifi scan")) { _ in
            NSLocalizedString("面板无法开始扫描 Wi-Fi，请稍后重试", comment: "board error: failed to start wifi scan")
        },
        BoardRule(.exact("invalid ssid or password")) { _ in
            NSLocalizedString("Wi-Fi 名称或密码无效", comment: "board error: invalid ssid or password")
        },
        BoardRule(.exact("invalid mode"), .exact("invalid targetMode")) { _ in
            NSLocalizedString("面板不支持这个模式", comment: "board error: invalid mode")
        },
        BoardRule(.exact("AP IP changes require Bluetooth")) { _ in
            NSLocalizedString("修改热点 IP 需要通过蓝牙连接面板", comment: "board error: AP IP changes require Bluetooth")
        },
        BoardRule(.starts("invalid AP settings")) { _ in
            NSLocalizedString("热点设置无效或热点启动失败：IP 必须是私有网段的 IPv4 地址，且末位在 1 到 254 之间", comment: "board error: invalid AP settings")
        },
        BoardRule(.exact("BLE disabled in this build")) { _ in
            NSLocalizedString("这块面板的固件未启用蓝牙", comment: "board error: BLE disabled in this build")
        },

        // Device name, hint LED, colour
        BoardRule(.starts("name too long (max ")) { detail in
            String(format: NSLocalizedString("面板名称过长，最多 %@ 字节", comment: "board error: device name too long; argument is the byte limit"), leadingNumber(detail))
        },
        BoardRule(.exact("name is not valid UTF-8")) { _ in
            NSLocalizedString("面板名称包含无效字符", comment: "board error: device name is not valid UTF-8")
        },
        BoardRule(.starts("led must be -1 or 0..")) { detail in
            String(format: NSLocalizedString("提示灯编号无效，必须是 -1 或 0 到 %@", comment: "board error: hint led index out of range; argument is the highest index"), leadingNumber(detail))
        },
        BoardRule(.starts("mirror must be -1 or 0..")) { detail in
            String(format: NSLocalizedString("镜像提示灯编号无效，必须是 -1 或 0 到 %@", comment: "board error: hint mirror led index out of range; argument is the highest index"), leadingNumber(detail))
        },
        BoardRule(.starts("color must be #RRGGBB")) { _ in
            NSLocalizedString("颜色格式无效，需要 #RRGGBB", comment: "board error: invalid colour")
        },

        // Saved faces: storage and concurrency
        BoardRule(.exact("LittleFS is not mounted")) { _ in
            NSLocalizedString("面板存储不可用，请重启面板后重试", comment: "board error: LittleFS is not mounted")
        },
        BoardRule(.exact("saved faces changed; reload before writing")) { _ in
            NSLocalizedString("面板上的表情库已被改动，请刷新后重试", comment: "board error: saved faces changed; reload before writing")
        },
        BoardRule(.exact("face changed since it was loaded; reload before overwriting")) { _ in
            NSLocalizedString("这个表情在面板上已被改动，请刷新后重试", comment: "board error: face changed since it was loaded")
        },
        BoardRule(.exact("saved faces changed during upload"), .exact("saved_faces.json changed mid-transfer")) { _ in
            NSLocalizedString("传输过程中面板上的表情库发生了变化，请重试", comment: "board error: saved faces changed during a transfer")
        },
        BoardRule(.exact("boot_mismatch")) { _ in
            NSLocalizedString("面板已重启，请重新同步后重试", comment: "board error: boot_mismatch")
        },
        BoardRule(.ends(": saved_faces.json not found or unreadable")) { _ in
            NSLocalizedString("面板上的表情库文件无法读取", comment: "board error: saved_faces.json not found or unreadable")
        },
        BoardRule(.contains(": saved_faces.json parse failed: ")) { detail in
            String(format: NSLocalizedString("面板上的表情库文件已损坏：%@", comment: "board error: saved_faces.json parse failed; argument is the parser detail"), detail)
        },
        BoardRule(
            .exact("saved faces unavailable"), .exact("saved faces file unavailable"),
            .exact("no usable saved faces"), .exact("failed to expand saved faces"),
            .exact("incomplete saved faces snapshot")
        ) { _ in
            NSLocalizedString("面板上的表情库暂时不可用，请稍后重试", comment: "board error: saved faces unavailable")
        },
        BoardRule(.starts("failed to write/commit file: ")) { detail in
            String(format: NSLocalizedString("面板写入文件失败：%@", comment: "board error: failed to write a file; argument is the file path"), detail)
        },
        BoardRule(.exact("failed to ensure /resources for saved_faces.json")) { _ in
            NSLocalizedString("面板无法创建表情库文件", comment: "board error: failed to create the saved faces directory")
        },

        // Saved faces: capacity
        BoardRule(.starts("too many faces; firmware max is ")) { detail in
            String(format: NSLocalizedString("面板表情库已满，最多保存 %@ 个表情", comment: "board error: too many faces; argument is the limit"), leadingNumber(detail))
        },
        BoardRule(.exact("too many faces on disk for reorder"), .exact("missing faces array or too many faces")) { _ in
            NSLocalizedString("面板上的表情数量超出限制", comment: "board error: too many faces")
        },
        BoardRule(
            .exact("faces document too large"), .exact("saved_faces.json exceeds firmware size limit"),
            .exact("expanded saved_faces.json exceeds firmware size limit"),
            .exact("expanded saved faces exceed size limit")
        ) { _ in
            NSLocalizedString("表情库过大，超出面板的容量限制", comment: "board error: faces document too large")
        },
        BoardRule(
            .exact("insufficient memory for faces upload"), .exact("insufficient PSRAM for saved faces snapshot"),
            .exact("failed to allocate JSON serialization buffer"), .exact("failed to serialize JSON document"),
            .exact("failed to allocate prepared saved-face table"),
            .exact("failed to allocate saved-face identity strings"),
            .starts("insufficient JSON capacity for ")
        ) { _ in
            NSLocalizedString("面板内存不足，无法处理表情库", comment: "board error: out of memory while handling saved faces")
        },

        // Saved faces: one face
        BoardRule(.starts("saved face not found: ")) { detail in
            String(format: NSLocalizedString("面板上找不到表情 %@", comment: "board error: saved face not found; argument is the face id"), detail)
        },
        BoardRule(.exact("unknown face id")) { _ in
            NSLocalizedString("面板上找不到这个表情，可能已被删除", comment: "board error: unknown face id")
        },
        BoardRule(.exact("face id already exists")) { _ in
            NSLocalizedString("面板上已有相同的表情", comment: "board error: face id already exists")
        },
        BoardRule(.exact("cannot rename a default face")) { _ in
            NSLocalizedString("默认表情不能重命名", comment: "board error: cannot rename a default face")
        },
        BoardRule(.exact("cannot delete a default face")) { _ in
            NSLocalizedString("默认表情不能删除", comment: "board error: cannot delete a default face")
        },
        BoardRule(.exact("cannot overwrite a default face")) { _ in
            NSLocalizedString("默认表情不能覆盖", comment: "board error: cannot overwrite a default face")
        },
        BoardRule(
            .exact("cannot remove the last default face"),
            .exact("saved_faces.json must keep at least one type:\"default\" face")
        ) { _ in
            NSLocalizedString("面板上至少要保留一个默认表情", comment: "board error: cannot remove the last default face")
        },
        BoardRule(.exact("name must be 1..64 chars"), .exact("face.name must be 1..64 bytes")) { _ in
            NSLocalizedString("表情名称不能为空，且不能超过 64 字节", comment: "board error: face name length")
        },
        BoardRule(.starts("ids must list every face exactly once")) { _ in
            NSLocalizedString("表情顺序与面板上的表情库不一致，请刷新后重试", comment: "board error: reorder ids do not match the stored faces")
        },
        BoardRule(.exact("face.type must be custom or parts"), .exact("face.type must be default, custom, or parts")) { _ in
            NSLocalizedString("面板不支持这种表情类型", comment: "board error: unsupported face type")
        },
        BoardRule(.exact("unsupported parts catalog/version")) { _ in
            NSLocalizedString("面板不支持这个版本的部件表情", comment: "board error: unsupported parts catalog/version")
        },
        BoardRule(.starts("invalid part ID: "), .starts("missing or invalid part ID: ")) { detail in
            String(format: NSLocalizedString("表情部件编号无效：%@", comment: "board error: invalid part id; argument is the part field"), detail)
        },
        BoardRule(.exact("unknown part ID or incorrect part group")) { _ in
            NSLocalizedString("表情部件编号无效", comment: "board error: unknown part id")
        },
        BoardRule(
            .exact("face.frameHex must be 94 hex chars"), .exact("face.frameHex contains invalid hex digit"),
            .starts("face.frameBytes must "), .exact("face.frameBytes entries must be 0..255"),
            .starts("invalid face packed frame: "), .exact("packed frame has non-zero unused bits"),
            .exact("SET_FRAME payload too short"), .exact("SET_FRAME payload truncated")
        ) { _ in
            NSLocalizedString("表情画面数据无效", comment: "board error: invalid face frame data")
        },

        // Scrolling text
        BoardRule(.exact("scroll upload already in progress")) { _ in
            NSLocalizedString("面板正在接收另一段滚动文字，请稍后重试", comment: "board error: scroll upload already in progress")
        },
        BoardRule(.exact("scroll upload was superseded")) { _ in
            NSLocalizedString("这次滚动文字上传已被新的上传取代", comment: "board error: scroll upload was superseded")
        },
        BoardRule(
            .exact("too many scroll frames"), .exact("scroll chunk exceeds totalFrames"),
            .exact("scroll upload too large"), .exact("scroll_bitmap upload too large")
        ) { _ in
            NSLocalizedString("滚动文字过长，超出面板可接收的帧数", comment: "board error: too many scroll frames")
        },
        BoardRule(.exact("sourceText too large")) { _ in
            NSLocalizedString("文字内容过长，超出面板限制", comment: "board error: sourceText too large")
        },
        BoardRule(.starts("insufficient memory for scroll"), .exact("scroll frame buffer unavailable")) { _ in
            NSLocalizedString("面板内存不足，无法接收滚动文字", comment: "board error: out of memory for a scroll upload")
        },
        BoardRule(.exact("failed to write scroll frames")) { _ in
            NSLocalizedString("面板保存滚动文字失败", comment: "board error: failed to write scroll frames")
        },
        BoardRule(.starts("invalid scroll frame: ")) { _ in
            NSLocalizedString("滚动文字的画面数据无效", comment: "board error: invalid scroll frame")
        },
        BoardRule(.exact("no_timeline")) { _ in
            NSLocalizedString("面板上没有可播放的滚动文字，请重新发送", comment: "board error: no_timeline")
        },

        // Blob transfer
        BoardRule(
            .exact("no active blob session"), .exact("incomplete blob upload"),
            .exact("incomplete scroll_bitmap upload"), .exact("unexpected chunk offset"),
            .exact("chunk exceeds declared blob size")
        ) { _ in
            NSLocalizedString("数据上传中断，请重试", comment: "board error: blob upload out of sequence or incomplete")
        },
    ]

    // MARK: - Decoding errors

    private static func decodingMessage(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return String(
                format: NSLocalizedString("数据无法解析：缺少字段 %@", comment: "decoding error: missing key; argument is the field path"),
                fieldPath(context.codingPath + [key])
            )
        case .valueNotFound(_, let context):
            guard !context.codingPath.isEmpty else { return corruptedMessage() }
            return String(
                format: NSLocalizedString("数据无法解析：字段 %@ 没有值", comment: "decoding error: null value; argument is the field path"),
                fieldPath(context.codingPath)
            )
        case .typeMismatch(_, let context):
            guard !context.codingPath.isEmpty else { return corruptedMessage() }
            return String(
                format: NSLocalizedString("数据无法解析：字段 %@ 的类型不符", comment: "decoding error: type mismatch; argument is the field path"),
                fieldPath(context.codingPath)
            )
        case .dataCorrupted(let context):
            guard !context.codingPath.isEmpty else { return corruptedMessage() }
            return String(
                format: NSLocalizedString("数据无法解析：字段 %@ 的内容无效", comment: "decoding error: corrupted value; argument is the field path"),
                fieldPath(context.codingPath)
            )
        @unknown default:
            return corruptedMessage()
        }
    }

    private static func corruptedMessage() -> String {
        NSLocalizedString("数据无法解析：格式不正确", comment: "decoding error: the data as a whole is malformed")
    }

    /// `faces[3].frameHex` style path.
    private static func fieldPath(_ path: [any CodingKey]) -> String {
        var out = ""
        for key in path {
            if let index = key.intValue {
                out += "[\(index)]"
            } else {
                if !out.isEmpty { out += "." }
                out += key.stringValue
            }
        }
        return out
    }
}

public extension Error {
    /// `RinaErrorText.message(for: self)`.
    var rinaUserMessage: String { RinaErrorText.message(for: self) }
}
