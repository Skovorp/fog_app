import SwiftUI

/// Sliding bar at the bottom of the live recording screen. One tile per
/// captured frame; newest on the right; older tiles shift left as new frames
/// stream in.
///
/// Per-tile rendering:
///   - **unprocessed** (no score yet): full-height grey, with a deterministic
///     per-frame brightness jitter so the bar's motion is visible.
///   - **processed**: a histogram-style fill rising from the bottom of the
///     tile. Score 0 → 10% fill (green), score 1 → 100% fill (red). The unfilled
///     top is fully transparent — the camera preview shows through.
///
/// Tiles auto-size so that exactly `visibleSeconds * fps` of footage is on
/// screen at any given moment.
struct FrameBarView: View {
    let frames: [FrameBuffer.Frame]

    private let visibleSeconds: Double = 10.0
    private let fps: Double = 24.0
    private let barHeight: CGFloat = 90
    private let minFillFraction: CGFloat = 0.10
    private let minTextWidth: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let count = frames.count
            guard count > 0, size.width > 0 else { return }

            let targetVisible = max(1, Int((visibleSeconds * fps).rounded()))
            let squareWidth = size.width / CGFloat(targetVisible)
            let visibleCount = min(count, targetVisible)
            let startIdx = count - visibleCount
            let showText = squareWidth >= minTextWidth

            for i in startIdx..<count {
                let positionFromRight = CGFloat(count - 1 - i)
                let x = size.width - (positionFromRight + 1) * squareWidth
                let frame = frames[i]

                if let score = frame.score {
                    let clipped = CGFloat(max(0, min(1, score)))
                    let fillFraction = minFillFraction + clipped * (1 - minFillFraction)
                    let fillHeight = size.height * fillFraction
                    let rect = CGRect(x: x, y: size.height - fillHeight, width: squareWidth, height: fillHeight)
                    context.fill(Path(rect), with: .color(scoreColor(score)))

                    // Red cap on tiles that cross the 0.5 threshold — makes "above
                    // 50%" segments instantly readable as a contiguous red bar.
                    if score > 0.5 {
                        let capHeight: CGFloat = 3
                        let capRect = CGRect(x: x, y: size.height - fillHeight, width: squareWidth, height: capHeight)
                        context.fill(Path(capRect), with: .color(.red))
                    }

                    if showText {
                        let percent = Int((score * 100).rounded())
                        let text = Text("\(percent)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                        let resolved = context.resolve(text)
                        let textSize = resolved.measure(in: CGSize(width: squareWidth, height: fillHeight))
                        let textRect = CGRect(
                            x: x + (squareWidth - textSize.width) / 2,
                            y: size.height - fillHeight + max(0, (fillHeight - textSize.height) / 2),
                            width: textSize.width,
                            height: textSize.height
                        )
                        context.draw(resolved, in: textRect)
                    }
                } else {
                    let rect = CGRect(x: x, y: 0, width: squareWidth, height: size.height)
                    context.fill(Path(rect), with: .color(greyJitter(frame.index)))
                }
            }

            drawGuides(context: context, size: size)
        }
        .frame(height: barHeight)
        .allowsHitTesting(false)
    }

    /// Horizontal reference lines at 0/25/50/75/100% scores, with right-edge
    /// labels. Drawn last so they sit on top of tiles.
    private func drawGuides(context: GraphicsContext, size: CGSize) {
        let stops: [Int] = [0, 25, 50, 75, 100]
        let labelWidth: CGFloat = 26
        let lineColor = Color.white.opacity(0.35)

        for p in stops {
            let score = CGFloat(p) / 100
            let fillFraction = minFillFraction + score * (1 - minFillFraction)
            let y = size.height - size.height * fillFraction

            let isExtreme = p == 0 || p == 100
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width - labelWidth, y: y))
            context.stroke(
                path,
                with: .color(lineColor),
                style: StrokeStyle(
                    lineWidth: isExtreme ? 1 : 0.7,
                    dash: isExtreme ? [] : [3, 3]
                )
            )

            let text = Text("\(p)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
            let resolved = context.resolve(text)
            let textSize = resolved.measure(in: CGSize(width: labelWidth, height: 14))
            let centerY = y - textSize.height / 2
            let clampedY = min(max(centerY, 0), size.height - textSize.height)
            let textRect = CGRect(
                x: size.width - textSize.width - 4,
                y: clampedY,
                width: textSize.width,
                height: textSize.height
            )
            context.draw(resolved, in: textRect)
        }
    }

    /// Red close to 1, green close to 0.
    private func scoreColor(_ score: Float) -> Color {
        let clipped = Double(max(0, min(1, score)))
        let hue = (1.0 - clipped) * 0.33
        return Color(hue: hue, saturation: 0.85, brightness: 0.95)
    }

    /// Deterministic per-frame brightness so the bar visibly slides even when
    /// no inference results have come back yet.
    private func greyJitter(_ index: Int) -> Color {
        let h = UInt32(bitPattern: Int32(truncatingIfNeeded: index)) &* 2_654_435_761
        let n = Double(h & 0xFFFF) / 65_535.0
        return Color(white: 0.22 + n * 0.22).opacity(0.85)
    }
}

#Preview("FrameBar — synthetic") {
    let frames: [FrameBuffer.Frame] = (0..<400).map { i in
        var f = FrameBuffer.Frame(index: i, pixelBuffer: nil)
        let score: Float?
        if i < 64 { score = nil }
        else if i < 200 { score = Float(i - 64) / 135.0 }
        else { score = Float.random(in: 0...1) }
        if let score {
            f.scoreSum = score
            f.scoreCount = 1
        }
        return f
    }
    ZStack {
        LinearGradient(colors: [.indigo, .purple, .black], startPoint: .top, endPoint: .bottom)
        VStack {
            Spacer()
            FrameBarView(frames: frames)
        }
    }
}
