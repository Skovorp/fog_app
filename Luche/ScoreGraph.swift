import AVFoundation
import SwiftUI

/// Per-frame score timeseries rendered beneath the trial-rewatch video.
///
/// Mirrors the web `ScoreGraph` (luche.ai) so the two surfaces feel identical:
///   - System AVKit `VideoPlayer` sits above, untouched — it owns the
///     transport (play/pause/scrub/AirPlay/PiP). We only read its
///     `currentTime` and write it back on drag.
///   - This view paints the line + area + threshold + playhead.
///   - Playhead motion is driven by `addPeriodicTimeObserver` updating
///     `@State currentTime` — the canonical AVPlayer + SwiftUI pattern.
///     `TimelineView(.animation)` was tried first but Canvas doesn't
///     reliably invalidate when its only time-varying input is a non-
///     observable method call (`player.currentTime`).
///   - Drag anywhere on the panel to seek; the gesture maps x → time using
///     the same 16 px inset as the web build.
///
/// Path construction (line + area) happens inside the Canvas closure today.
/// At ~750 frames per typical Luche clip this stays well above 60fps on the
/// iPhone 14 baseline; if it ever drops, lift the Paths into `@State`
/// computed only when `scores`/`size` change.
struct ScoreGraph: View {
    let player: AVPlayer
    let scores: [Float]
    /// FoG threshold (typically `Session.fogThreshold = 0.5`). Pass `nil` for
    /// continuous-severity evaluations to hide the dashed reference line.
    let threshold: Float?

    /// Matches web: aligned to the WebKit native scrubber padding. iOS
    /// AVKit's scrubber sits closer to the edges, so this is the rough
    /// equivalent; verify visually with a sim screenshot once we wire it in.
    private let inset: CGFloat = 16
    private let panelHeight: CGFloat = 96

    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var observerToken: Any?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(into: ctx, size: size, at: currentTime)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in seek(toX: value.location.x, width: geo.size.width) }
            )
        }
        .frame(height: panelHeight)
        .background(Color.lucheInk)
        .task(id: ObjectIdentifier(player)) { await loadDuration() }
        .onAppear(perform: attachObserver)
        .onDisappear(perform: detachObserver)
    }

    // MARK: - Drawing

    private func draw(into ctx: GraphicsContext, size: CGSize, at currentTime: Double) {
        let n = scores.count
        guard n >= 2, size.width > 4, size.height > 4 else { return }

        let W = size.width, H = size.height
        let x0 = inset
        let x1 = max(x0 + 1, W - inset)
        let trackW = x1 - x0
        let pad: CGFloat = 10
        let valY: (Float) -> CGFloat = { v in
            let clipped = CGFloat(max(0, min(1, Double(v))))
            return pad + (1 - clipped) * (H - 2 * pad)
        }
        let xOf: (Int) -> CGFloat = { i in
            x0 + CGFloat(i) / CGFloat(n - 1) * trackW
        }

        // Threshold reference line — FoG mode only.
        if let t = threshold, t > 0, t < 1 {
            var thr = Path()
            let ty = valY(t)
            thr.move(to: CGPoint(x: x0, y: ty))
            thr.addLine(to: CGPoint(x: x1, y: ty))
            ctx.stroke(
                thr,
                with: .color(.white.opacity(0.22)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            ctx.draw(
                Text(String(format: "%.2f", t))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4)),
                at: CGPoint(x: 4, y: ty - 8),
                anchor: .topLeading
            )
        }

        // Area fill (gradient: red top → green bottom).
        var area = Path()
        area.move(to: CGPoint(x: x0, y: valY(scores[0])))
        for i in 1..<n { area.addLine(to: CGPoint(x: xOf(i), y: valY(scores[i]))) }
        area.addLine(to: CGPoint(x: x1, y: H))
        area.addLine(to: CGPoint(x: x0, y: H))
        area.closeSubpath()
        ctx.fill(
            area,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 1.0, green: 0.33, blue: 0.44).opacity(0.32), location: 0),
                    .init(color: Color(red: 1.0, green: 0.82, blue: 0.4).opacity(0.16), location: 0.5),
                    .init(color: Color(red: 0.22, green: 0.84, blue: 0.48).opacity(0.05), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: H)
            )
        )

        // Single polyline. (Shadow via drawLayer for parity with web.)
        var line = Path()
        line.move(to: CGPoint(x: x0, y: valY(scores[0])))
        for i in 1..<n { line.addLine(to: CGPoint(x: xOf(i), y: valY(scores[i]))) }
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.55), radius: 1.5, y: 1))
            layer.stroke(
                line,
                with: .color(.white.opacity(0.92)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
        }

        // Playhead — `currentTime` is driven by the periodic time observer
        // (see attachObserver) so SwiftUI redraws Canvas on every tick.
        let dur = duration > 0 ? duration : 1
        let frac = max(0, min(1, currentTime / dur))
        let head = max(0, min(n - 1, Int((frac * Double(n - 1)).rounded(.down))))
        let hx = xOf(head)
        let hy = valY(scores[head])

        var vline = Path()
        vline.move(to: CGPoint(x: hx, y: 0))
        vline.addLine(to: CGPoint(x: hx, y: H))
        ctx.stroke(vline, with: .color(.white.opacity(0.9)), lineWidth: 1.5)

        let dot = Path(ellipseIn: CGRect(x: hx - 5, y: hy - 5, width: 10, height: 10))
        ctx.fill(dot, with: .color(.white))

        let ring = Path(ellipseIn: CGRect(x: hx - 8, y: hy - 8, width: 16, height: 16))
        ctx.stroke(ring, with: .color(scoreColor(scores[head])), lineWidth: 2)
    }

    // MARK: - Interaction

    private func seek(toX x: CGFloat, width: CGFloat) {
        guard duration > 0 else { return }
        let trackW = max(1, width - 2 * inset)
        let frac = max(0, min(1, (x - inset) / trackW))
        let t = Double(frac) * duration
        player.seek(
            to: CMTime(seconds: t, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    // MARK: - Setup

    private func loadDuration() async {
        guard let item = player.currentItem else { return }
        do {
            let d = try await item.asset.load(.duration)
            await MainActor.run { duration = d.seconds }
        } catch {
            // Fall back to whatever the player reports; remains 0 → seeks no-op.
        }
    }

    /// Subscribe to AVPlayer time updates at ~30 Hz on the main queue.
    /// Each callback writes `currentTime`, which invalidates the body and
    /// pulls Canvas through its renderer with the new playhead position.
    /// 30 Hz is plenty for the playhead — display refresh would be wasted
    /// work given the human-eye-perceptible motion threshold for a 1.5 px
    /// vertical marker creeping across a 350 pt strip.
    private func attachObserver() {
        guard observerToken == nil else { return }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        observerToken = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { time in
            currentTime = time.seconds
        }
    }

    private func detachObserver() {
        if let token = observerToken {
            player.removeTimeObserver(token)
            observerToken = nil
        }
    }

    // MARK: - Visual helpers

    private func scoreColor(_ v: Float) -> Color {
        let clipped = Double(max(0, min(1, v)))
        let hue = (1 - clipped) * 0.33  // 0 = red, 0.33 = green
        return Color(hue: hue, saturation: 0.85, brightness: 0.95)
    }
}

#Preview("ScoreGraph — synthetic FoG run") {
    // Build a synthetic series with two freezing episodes, ~30 fps, ~25 s.
    let fps: Float = 30
    let dur: Float = 25
    let n = Int(fps * dur)
    let scores: [Float] = (0..<n).map { i in
        let t = Float(i) / fps
        var base: Float = 0.10
        if t > 6, t < 9.5 { base = 0.82 }
        if t > 14.5, t < 18.2 { base = 0.91 }
        if t > 21, t < 22.5 { base = 0.55 }
        return min(1, max(0, base + Float.random(in: -0.06...0.06)))
    }
    return ZStack(alignment: .bottom) {
        Color.black
        ScoreGraph(player: AVPlayer(), scores: scores, threshold: 0.5)
    }
    .frame(height: 200)
}
