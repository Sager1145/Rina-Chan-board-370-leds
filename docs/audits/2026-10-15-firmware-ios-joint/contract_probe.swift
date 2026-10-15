import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let font = try ArkPixelFont.loadBundled(url: root.appendingPathComponent("ios/RinaBoard/Resources/ark12.json"))
let text = "A" + String(repeating: "\u{200D}", count: 1365)
let timeline = try ScrollRasterizer.makeTimeline(text: text, font: font, fps: 10)
let meta: [String: Any] = [
    "kind": "scroll_bitmap", "totalBytes": timeline.bitmap.packedBytes().count,
    "width": timeline.bitmapWidth, "rows": MatrixGeometry.rows, "fps": 10,
    "intervalMs": ScrollRasterizer.intervalMs(forFps: 10),
    "timelineId": timeline.timelineId, "fontId": ScrollRasterizer.fontId,
    "generatorVersion": ScrollRasterizer.generatorVersion, "sourceText": timeline.text
]
let payload = try JSONSerialization.data(withJSONObject: meta)
precondition(timeline.text.utf8.count == RinaLinkConstants.maxScrollTextBytes)
precondition(timeline.frameCount <= RinaLinkConstants.maxScrollFrames)
print("admitted_text_bytes=\(timeline.text.utf8.count) timeline_frames=\(timeline.frameCount) begin_payload_bytes=\(payload.count) frame_limit=\(RinaLinkFrameConstants.maxPayloadBytes)")
do {
    try RinaLinkEncoder.validatePayloadSize(payload.count)
    fatalError("expected current metadata limit mismatch")
} catch { print("observed_upload_rejection=\(error)") }
let allIntervals = (RinaLinkConstants.scrollFpsMin...RinaLinkConstants.scrollFpsMax).map(ScrollRasterizer.intervalMs(forFps:))
precondition(allIntervals.min() == 17 && allIntervals.max() == 1000)
print("production_ui_scroll_interval_range=\(allIntervals.min()!)...\(allIntervals.max()!)")
let ack = try JSONDecoder().decode(CommandReply.self, from: Data("{\"ok\":true}".utf8))
precondition(ack.ok && ack.autoFaceId == nil && ack.autoFaceIndex == nil)
print("minimal_ack_decodes=true face_result_fields_absent=true")
let power = try JSONDecoder().decode(PowerStatus.self, from: Data("{\"ok\":true,\"power\":{\"batteryPercent\":62,\"batteryValid\":true}}".utf8))
precondition(power.batteryPercent == 62)
print("nested_power_envelope_decodes=true")
