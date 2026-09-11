import SwiftUI
import RinaCore

/// Shared 22×18 LED matrix renderer used by the Control preview, the pixel/parts
/// editor and the Debug page (FEATURE_INVENTORY A1, B1, C1).
///
/// - `frame`: the packed frame to draw (logical LED index → lit).
/// - `color` / `brightness`: global colour and 10…200 brightness, mirrored from the board.
/// - `onToggle`: when non-nil the matrix is editable: tapping a valid cell calls it with
///   the logical LED index (tap-to-toggle only, no drag, matching the WebUI).
/// - `showBoardImage`: draws the board photo behind the cells like the WebUI did.
struct LEDMatrixView: View {
    var frame: PackedFrame
    var color: Color = Color(hex: "#f971d4") ?? .pink
    var brightness: Int = 50
    var showBoardImage: Bool = true
    var onToggle: ((Int) -> Void)? = nil

    private let cols = MatrixGeometry.cols
    private let rows = MatrixGeometry.rows

    // Board photo geometry, ported from the WebUI stylesheet (.rinaboard-stage):
    // picture is 4000×3351 px; the 22×18 grid starts at (597.66, 850.71) with a
    // 127.43 px cell, all in picture space and scaled by stageWidth / 4000.
    private static let photoWidth: CGFloat = 4000
    private static let photoHeight: CGFloat = 3351
    private static let photoGridLeft: CGFloat = 597.66
    private static let photoGridTop: CGFloat = 850.71
    private static let photoCell: CGFloat = 127.43

    var body: some View {
        let usePhoto = showBoardImage && boardImage != nil
        GeometryReader { geo in
            let layout = cellLayout(in: geo.size, usePhoto: usePhoto)
            ZStack(alignment: .topLeading) {
                if usePhoto, let ui = boardImage {
                    Image(uiImage: ui)
                        .resizable()
                        .frame(width: layout.stage.width, height: layout.stage.height)
                        .offset(x: layout.stage.minX, y: layout.stage.minY)
                        .opacity(0.9)
                }
                Canvas { ctx, _ in
                    let litColor = litCellColor
                    let dot = layout.cell * 0.72
                    for y in 0..<rows {
                        guard let xr = MatrixGeometry.validXRange(row: y) else { continue }
                        for x in xr {
                            guard let idx = MatrixGeometry.ledIndex(x: x, y: y) else { continue }
                            let cx = layout.originX + (CGFloat(x) + 0.5) * layout.cell
                            let cy = layout.originY + (CGFloat(y) + 0.5) * layout.cell
                            let rect = CGRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot)
                            let path = Path(ellipseIn: rect)
                            if frame[idx] {
                                ctx.fill(path, with: .color(litColor))
                            } else {
                                ctx.fill(path, with: .color(usePhoto ? Color.black.opacity(0.28) : Color.primary.opacity(0.12)))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(tapGesture(cell: layout.cell, originX: layout.originX, originY: layout.originY))
            }
        }
        .aspectRatio(usePhoto ? Self.photoWidth / Self.photoHeight : CGFloat(cols) / CGFloat(rows), contentMode: .fit)
        .accessibilityLabel("LED 矩阵，\(frame.litCount) 颗点亮")
    }

    private struct CellLayout {
        var cell: CGFloat
        var originX: CGFloat
        var originY: CGFloat
        var stage: CGRect
    }

    private func cellLayout(in size: CGSize, usePhoto: Bool) -> CellLayout {
        if usePhoto {
            let scale = min(size.width / Self.photoWidth, size.height / Self.photoHeight)
            let stageW = Self.photoWidth * scale
            let stageH = Self.photoHeight * scale
            let stage = CGRect(x: (size.width - stageW) / 2, y: (size.height - stageH) / 2, width: stageW, height: stageH)
            return CellLayout(cell: Self.photoCell * scale,
                              originX: stage.minX + Self.photoGridLeft * scale,
                              originY: stage.minY + Self.photoGridTop * scale,
                              stage: stage)
        }
        let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
        let gridW = cell * CGFloat(cols)
        let gridH = cell * CGFloat(rows)
        return CellLayout(cell: cell,
                          originX: (size.width - gridW) / 2,
                          originY: (size.height - gridH) / 2,
                          stage: .zero)
    }

    private var litCellColor: Color {
        // Approximate perceived brightness: 10…200 → 0.35…1.0
        let b = Double(max(10, min(200, brightness)))
        let alpha = 0.35 + 0.65 * ((b - 10) / 190)
        return color.opacity(alpha)
    }

    private func tapGesture(cell: CGFloat, originX: CGFloat, originY: CGFloat) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard let onToggle else { return }
            let x = Int((value.location.x - originX) / cell)
            let y = Int((value.location.y - originY) / cell)
            guard x >= 0, y >= 0, x < cols, y < rows, let idx = MatrixGeometry.ledIndex(x: x, y: y) else { return }
            onToggle(idx)
        }
    }

    private static let cachedBoardImage: UIImage? = {
        if let url = Bundle.main.url(forResource: "rinaboard", withExtension: "png") {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }()

    private var boardImage: UIImage? { Self.cachedBoardImage }
}

extension Color {
    /// Parses "#RRGGBB" / "RRGGBB" (case-insensitive).
    init?(hex: String) {
        guard let (r, g, b) = RGBHex.parseHex(hex) else { return nil }
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// "#rrggbb" for an sRGB colour.
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBHex.formatHex(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
    }
}

#Preview {
    var f = PackedFrame()
    for i in stride(from: 0, to: 370, by: 3) { f[i] = true }
    return LEDMatrixView(frame: f, onToggle: { _ in })
        .padding()
}
