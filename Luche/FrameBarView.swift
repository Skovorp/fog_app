import SwiftUI

/// Sliding bar at the bottom of the live recording screen. One tile per
/// captured frame; newest on the right; older tiles shift left as new frames
/// stream in.
///
/// Per-tile rendering:
///   - **unprocessed** (no score yet): full-height grey, with a deterministic
///     per-frame brightness jitter so the bar's motion is visible.
///   - **processed**: a histogram-style fill rising from the bottom of the
///     tile. The fill scales by `score / scoreRange.upperBound`, so the
///     visual mapping (green at 0 → red at the top of the scale) is the
///     same for FoG/chair (0–1) and walking/tapping (0–4).
///
/// Tiles auto-size so that exactly `visibleSeconds * fps` of footage is on
/// screen at any given moment.
struct FrameBarView: View {
    let frames: [FrameBuffer.Frame]
    /// Display range for the score axis. FoG / chair → 0…1; walking /
    /// tapping → 0…4 (raw MDS-UPDRS). Drives normalization for color,
    /// fill height, threshold cap, and the per-tile label format.
    let scoreRange: ClosedRange<Float>

    private let visibleSeconds: Double = 10.0
    private let fps: Double = 24.0
    private let barHeight: CGFloat = 90
    private let minFillFraction: CGFloat = 0.10
    private let minTextWidth: CGFloat = 12

    /// Normalized score in [0, 1] for color / fill arithmetic.
    private func normalized(_ score: Float) -> CGFloat {
        let lo = scoreRange.lowerBound
        let hi = scoreRange.upperBound
        let span = max(hi - lo, .leastNonzeroMagnitude)
        let clipped = Swift.max(lo, Swift.min(hi, score))
        return CGFloat((clipped - lo) / span)
    }

    var body: some View {
        Canvas { context, size in
            let count = frames.count
            guard count > 0, size.width > 0 else { return }

            let targetVisible = max(1, Int((visibleSeconds * fps).rounded()))
            let squareWidth = size.width / CGFloat(targetVisible)
            let visibleCount = min(count, targetVisible)
            let startIdx = count - visibleCount
            let showText = squareWidth >= minTextWidth
            // 0.5 of FoG's [0,1] range; same proportional cutoff for [0,4].
            let halfMark = (scoreRange.lowerBound + scoreRange.upperBound) / 2

            for i in startIdx..<count {
                let positionFromRight = CGFloat(count - 1 - i)
                let x = size.width - (positionFromRight + 1) * squareWidth
                let frame = frames[i]

                if let score = frame.score {
                    let norm = normalized(score)
                    let fillFraction = minFillFraction + norm * (1 - minFillFraction)
                    let fillHeight = size.height * fillFraction
                    let rect = CGRect(x: x, y: size.height - fillHeight, width: squareWidth, height: fillHeight)
                    context.fill(Path(rect), with: .color(scoreColor(score)))

                    // Red cap on tiles past the halfway mark of the score
                    // range — instant visual cue for "above 50% of scale".
                    if score > halfMark {
                        let capHeight: CGFloat = 3
                        let capRect = CGRect(x: x, y: size.height - fillHeight, width: squareWidth, height: capHeight)
                        context.fill(Path(capRect), with: .color(.red))
                    }

                    if showText {
                        let text = Text(tileLabel(for: score))
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

    /// Horizontal reference lines at 0/25/50/75/100% of the score range,
    /// with right-edge labels — percentage for FoG/chair (0–1 range),
    /// actual score for walking/tapping (0–4 range).
    private func drawGuides(context: GraphicsContext, size: CGSize) {
        let stops: [CGFloat] = [0, 0.25, 0.5, 0.75, 1.0]
        let labelWidth: CGFloat = 26
        let lineColor = Color.white.opacity(0.35)
        let upper = scoreRange.upperBound
        let useRawScale = upper > 1.0

        for fraction in stops {
            let fillFraction = minFillFraction + fraction * (1 - minFillFraction)
            let y = size.height - size.height * fillFraction

            let isExtreme = fraction == 0 || fraction == 1
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

            let label: String
            if useRawScale {
                let value = scoreRange.lowerBound + Float(fraction) * (upper - scoreRange.lowerBound)
                label = String(format: "%.0f", value)
            } else {
                label = "\(Int((fraction * 100).rounded()))"
            }
            let text = Text(label)
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

    /// Per-tile label format. For a [0,1] range we show the integer percent
    /// (matches the original FoG bar); for a [0,4] range we show one
    /// decimal of the raw 0–4 score.
    private func tileLabel(for score: Float) -> String {
        if scoreRange.upperBound > 1 {
            return String(format: "%.1f", score)
        }
        return "\(Int((score * 100).rounded()))"
    }

    /// Red close to the top of the score range, green close to the bottom.
    private func scoreColor(_ score: Float) -> Color {
        let norm = Double(normalized(score))
        let hue = (1.0 - norm) * 0.33
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
        LinearGradient(colors: [.indigo, .purple, .lucheInk], startPoint: .top, endPoint: .bottom)
        VStack {
            Spacer()
            FrameBarView(frames: frames, scoreRange: 0...1)
        }
    }
}
