import Foundation
import UIKit

/// Generates a one-page landscape PDF for a `Session`: title, timestamp, stats
/// block, and a per-frame fog-probability line plot with a 0.5 threshold band.
enum SessionPDF {
    /// US Letter landscape, 72 dpi.
    static let pageRect = CGRect(x: 0, y: 0, width: 792, height: 612)

    static func generate(_ session: Session) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(session.exportFilenameStem).pdf")

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: pdfFormat(for: session))
        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            drawPage(session, in: pageRect)
        }
        return url
    }

    /// Render one session into the current PDF page. Exposed so
    /// `SessionExport.generateAllPDF` can stitch many sessions into one file.
    static func drawPage(_ session: Session, in rect: CGRect) {
        draw(session, in: rect)
    }

    private static func pdfFormat(for session: Session) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: session.displayTitle,
            kCGPDFContextCreator as String: "feral: parkinson's",
        ]
        return format
    }

    private static func draw(_ session: Session, in rect: CGRect) {
        let margin: CGFloat = 50
        var y: CGFloat = margin
        let evaluation = session.effectiveEvaluation
        let isFog = evaluation.headlinesFogPct

        // Title — evaluation name
        evaluation.displayName.draw(at: CGPoint(x: margin, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: UIColor.black,
        ])
        y += 46

        // Subtitle — UPDRS item · timestamp
        let subtitle = "\(evaluation.updrsItem) · \(session.timestampString)"
        subtitle.draw(at: CGPoint(x: margin, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: UIColor.darkGray,
        ])
        y += 24

        // Research-preview caveat for non-FoG evaluations
        if !isFog {
            "Demo score · research preview".draw(at: CGPoint(x: margin, y: y), withAttributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: UIColor.systemOrange.withAlphaComponent(0.85),
            ])
            y += 16
        }
        y += 12

        // Stats — 4 columns spread across the page; columns depend on evaluation
        let durMin = Int(session.duration) / 60
        let durSec = Int(session.duration) % 60
        let stats: [(String, String)]
        if isFog {
            stats = [
                ("Duration", "\(durMin)m \(durSec)s"),
                ("Total frames", "\(session.totalFrames)"),
                ("Fog frames", "\(session.fogCount)"),
                ("Fog %", String(format: "%.1f%%", session.fogPct)),
            ]
        } else {
            stats = [
                ("Duration", "\(durMin)m \(durSec)s"),
                ("Total frames", "\(session.totalFrames)"),
                ("Score (0-1)", String(format: "%.2f", session.updrsScore)),
                ("Band", session.updrsBand),
            ]
        }
        let statsBottom = drawStatsRow(stats, in: CGRect(
            x: margin, y: y, width: rect.width - 2 * margin, height: 0
        ))
        y = statsBottom + 28

        // Section header for the graph
        let graphHeader = isFog ? "Fog probability per frame" : "Model probability per frame"
        graphHeader.draw(at: CGPoint(x: margin, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor.darkGray,
        ])
        y += 22

        // Graph fills remaining height above the footer
        let graphRect = CGRect(
            x: margin + 32, // leave room for y-axis labels
            y: y,
            width: rect.width - 2 * margin - 32,
            height: rect.height - y - margin - 30
        )
        drawGraph(scores: session.scores, in: graphRect, showFogThreshold: isFog)

        // Footer
        let footer = "feral: parkinson's"
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor.lightGray,
        ]
        let footerSize = (footer as NSString).size(withAttributes: footerAttrs)
        footer.draw(
            at: CGPoint(x: rect.width - margin - footerSize.width,
                        y: rect.height - margin / 2 - footerSize.height),
            withAttributes: footerAttrs
        )
    }

    /// Draws label/value pairs as evenly-spaced columns. Returns the bottom y
    /// of the value text so the caller can lay out what comes after it.
    @discardableResult
    private static func drawStatsRow(_ stats: [(String, String)], in rect: CGRect) -> CGFloat {
        guard !stats.isEmpty else { return rect.minY }
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.darkGray,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: UIColor.black,
        ]
        let labelHeight: CGFloat = 16
        let valueHeight: CGFloat = 30

        let colWidth = rect.width / CGFloat(stats.count)
        for (i, (k, v)) in stats.enumerated() {
            let x = rect.minX + colWidth * CGFloat(i)
            (k as NSString).draw(at: CGPoint(x: x, y: rect.minY), withAttributes: labelAttrs)
            (v as NSString).draw(at: CGPoint(x: x, y: rect.minY + labelHeight + 4), withAttributes: valueAttrs)
        }
        return rect.minY + labelHeight + 4 + valueHeight
    }

    private static func drawGraph(scores: [Float], in rect: CGRect, showFogThreshold: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: UIColor.gray,
        ]

        // Plot frame
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(rect)

        // Y-axis gridlines + labels (0, 0.25, 0.5, 0.75, 1.0)
        for v in stride(from: 0.0, through: 1.0, by: 0.25) {
            let yPos = rect.maxY - rect.height * CGFloat(v)
            let label = String(format: "%.2f", v)
            let labelSize = (label as NSString).size(withAttributes: labelAttrs)
            (label as NSString).draw(
                at: CGPoint(x: rect.minX - labelSize.width - 6, y: yPos - labelSize.height / 2),
                withAttributes: labelAttrs
            )
            ctx.setStrokeColor(UIColor.lightGray.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(0.3)
            ctx.move(to: CGPoint(x: rect.minX, y: yPos))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos))
            ctx.strokePath()
        }

        guard !scores.isEmpty else {
            let msg = "No scored frames"
            let size = (msg as NSString).size(withAttributes: labelAttrs)
            (msg as NSString).draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: labelAttrs
            )
            return
        }

        let n = scores.count

        if showFogThreshold {
            // Fog regions filled (above threshold) — light red bars
            ctx.setFillColor(UIColor.systemRed.withAlphaComponent(0.16).cgColor)
            var i = 0
            while i < n {
                if scores[i] >= Session.fogThreshold {
                    var j = i
                    while j < n && scores[j] >= Session.fogThreshold { j += 1 }
                    let x0 = rect.minX + rect.width * CGFloat(i) / CGFloat(n)
                    let x1 = rect.minX + rect.width * CGFloat(j) / CGFloat(n)
                    ctx.fill(CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height))
                    i = j
                } else {
                    i += 1
                }
            }

            // Threshold line at 0.5 (dashed red)
            let thresholdY = rect.maxY - rect.height * CGFloat(Session.fogThreshold)
            ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(0.8)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: CGPoint(x: rect.minX, y: thresholdY))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: thresholdY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Score line
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(0.9)
        ctx.beginPath()
        let denom = CGFloat(max(n - 1, 1))
        for (idx, score) in scores.enumerated() {
            let x = rect.minX + rect.width * CGFloat(idx) / denom
            let clamped = max(0, min(1, CGFloat(score)))
            let yPos = rect.maxY - rect.height * clamped
            if idx == 0 {
                ctx.move(to: CGPoint(x: x, y: yPos))
            } else {
                ctx.addLine(to: CGPoint(x: x, y: yPos))
            }
        }
        ctx.strokePath()

        // X-axis label
        let xLabel = "Frame index (0 — \(n - 1))"
        let xSize = (xLabel as NSString).size(withAttributes: labelAttrs)
        (xLabel as NSString).draw(
            at: CGPoint(x: rect.midX - xSize.width / 2, y: rect.maxY + 6),
            withAttributes: labelAttrs
        )
    }
}
