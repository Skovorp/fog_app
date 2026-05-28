import Foundation
import PDFKit
import UIKit

/// Bulk-export helpers: one combined PDF (TOC + per-session pages, with
/// internal page links) and one combined JSON for machine consumption.
enum SessionExport {
    // MARK: JSON

    /// Builds a single JSON file:
    ///   { "session1": { "predictions": [...], "metadata": {...} }, ... }
    /// Keys are `session1`, `session2`, ... in *display* order (newest first).
    /// Order isn't guaranteed by JSON — `metadata.session_index` and
    /// `metadata.started_at` are the authoritative sort keys.
    /// Snapshot the *current* device once on the main actor and pass it in;
    /// it's used as fallback metadata for any historical session that was
    /// saved before per-session device capture existed.
    static func generateAllJSON(_ sessions: [Session], fallbackDevice: DeviceInfo) throws -> URL {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var dict: [String: Any] = [:]
        for (i, session) in sessions.enumerated() {
            let device = session.device ?? fallbackDevice
            let metadata: [String: Any] = [
                "session_index": i + 1,
                "title": session.displayTitle,
                "started_at": isoFormatter.string(from: session.startedAt),
                "ended_at": isoFormatter.string(from: session.endedAt),
                "duration_seconds": session.duration,
                "total_frames": session.totalFrames,
                "fog_frames": session.fogCount,
                "fog_percent": session.fogPct,
                "fog_threshold": Session.fogThreshold,
                "device": device.jsonDict,
                "device_captured_at_recording": session.device != nil,
            ]
            dict["session\(i + 1)"] = [
                "predictions": session.scores,
                "metadata": metadata,
            ]
        }

        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("luche_sessions_\(filenameStamp()).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Videos ZIP

    /// Stages every existing session video into a temp directory with
    /// human-readable filenames, then zips the directory with NSFileCoordinator
    /// (`.forUploading` produces a .zip when the input is a directory).
    static func generateAllVideosZIP(_ sessions: [Session]) throws -> URL {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("luche_videos_staging_\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        var copied = 0
        for session in sessions {
            guard let src = VideoStore.existingURL(for: session) else { continue }
            let stem = "\(nameFormatter.string(from: session.startedAt))_\(session.id.uuidString.prefix(8))"
            let dst = stagingDir.appendingPathComponent("\(stem).mp4")
            try fm.copyItem(at: src, to: dst)
            copied += 1
        }
        guard copied > 0 else {
            throw NSError(
                domain: "SessionExport", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No session videos available to export."]
            )
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var resultURL: URL?
        var copyError: Error?
        let dest = fm.temporaryDirectory
            .appendingPathComponent("luche_videos_\(filenameStamp()).zip")

        coordinator.coordinate(
            readingItemAt: stagingDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: tempZipURL, to: dest)
                resultURL = dest
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let resultURL else {
            throw NSError(
                domain: "SessionExport", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "ZIP coordinator returned no URL."]
            )
        }
        return resultURL
    }

    // MARK: Combined upload bundle (videos + labels.json)

    /// Bundles all session videos + a sibling `labels.json` into one zip suitable
    /// for upload to the feral-api backend. Same NSFileCoordinator(.forUploading)
    /// trick as generateAllVideosZIP — the JSON is staged alongside the .mp4s
    /// before zipping so a single archive carries both.
    ///
    /// The JSON schema matches generateAllJSON, plus a per-session
    /// `metadata.video_file` field pointing at the `.mp4` inside the zip
    /// (nil when a session's video is missing on disk).
    static func generateAllForUploadZIP(
        _ sessions: [Session],
        fallbackDevice: DeviceInfo
    ) throws -> URL {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("luche_upload_staging_\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let nameFormatter = DateFormatter()
        nameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var labelsDict: [String: Any] = [:]
        var copiedVideos = 0
        for (i, session) in sessions.enumerated() {
            let device = session.device ?? fallbackDevice
            let stem = "\(nameFormatter.string(from: session.startedAt))_\(session.id.uuidString.prefix(8))"

            var videoFilenameInZip: Any = NSNull()
            if let src = VideoStore.existingURL(for: session) {
                let dst = stagingDir.appendingPathComponent("\(stem).mp4")
                try fm.copyItem(at: src, to: dst)
                videoFilenameInZip = "\(stem).mp4"
                copiedVideos += 1
            }

            let metadata: [String: Any] = [
                "session_index": i + 1,
                "title": session.displayTitle,
                "evaluation": session.effectiveEvaluation.displayName,
                "started_at": isoFormatter.string(from: session.startedAt),
                "ended_at": isoFormatter.string(from: session.endedAt),
                "duration_seconds": session.duration,
                "total_frames": session.totalFrames,
                "fog_frames": session.fogCount,
                "fog_percent": session.fogPct,
                "fog_threshold": Session.fogThreshold,
                "device": device.jsonDict,
                "device_captured_at_recording": session.device != nil,
                "video_file": videoFilenameInZip,
            ]
            labelsDict["session\(i + 1)"] = [
                "predictions": session.scores,
                "metadata": metadata,
            ]
        }

        guard copiedVideos > 0 else {
            throw NSError(
                domain: "SessionExport", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "No session videos available to upload."]
            )
        }

        let labelsURL = stagingDir.appendingPathComponent("labels.json")
        let labelsData = try JSONSerialization.data(
            withJSONObject: labelsDict,
            options: [.sortedKeys]
        )
        try labelsData.write(to: labelsURL, options: .atomic)

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var resultURL: URL?
        var copyError: Error?
        let dest = fm.temporaryDirectory
            .appendingPathComponent("luche_upload_\(filenameStamp()).zip")

        coordinator.coordinate(
            readingItemAt: stagingDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempZipURL in
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: tempZipURL, to: dest)
                resultURL = dest
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let resultURL else {
            throw NSError(
                domain: "SessionExport", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "ZIP coordinator returned no URL."]
            )
        }
        return resultURL
    }

    // MARK: Per-trial metadata (Flow A — POST /trials `metadata`)

    /// Builds the `metadata` JSON object sent with a single trial in the
    /// per-trial upload flow. Mirrors the per-session payload that
    /// `generateAllForUploadZIP` writes into labels.json, so the server-side
    /// `trials.metadata` jsonb carries the same richer data (per-frame scores,
    /// device, frame count, threshold) for later per-frame views.
    ///
    /// Keys use the snake_case the rest of the API expects. `started_at` /
    /// `ended_at` are ISO8601 with fractional seconds.
    static func trialMetadata(
        for session: Session,
        fallbackDevice: DeviceInfo
    ) -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let device = session.device ?? fallbackDevice
        return [
            "scores": session.scores,
            "device": device.jsonDict,
            "total_frames": session.totalFrames,
            "fog_frames": session.fogCount,
            "fog_percent": session.fogPct,
            "fog_threshold": Session.fogThreshold,
            "duration_seconds": session.duration,
            "evaluation": session.effectiveEvaluation.displayName,
            "started_at": isoFormatter.string(from: session.startedAt),
            "ended_at": isoFormatter.string(from: session.endedAt),
            "device_captured_at_recording": session.device != nil,
        ]
    }

    // MARK: PDF

    /// Builds a single PDF: page 1 is a sortable table of contents (with
    /// internal links into each session's page); the remaining pages are the
    /// per-session reports rendered through `SessionPDF.drawPage`.
    static func generateAllPDF(_ sessions: [Session]) throws -> URL {
        let pageRect = SessionPDF.pageRect

        // Render the multi-page document. Capture the TOC row rectangles in
        // top-left coords so we can convert them to PDF (bottom-left)
        // coordinates and add link annotations after the fact.
        var rowRectsTopLeft: [CGRect] = []
        let intermediateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("luche_sessions_intermediate_\(UUID().uuidString).pdf")

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: combinedPDFFormat(count: sessions.count))
        try renderer.writePDF(to: intermediateURL) { ctx in
            ctx.beginPage()
            rowRectsTopLeft = drawTOC(sessions: sessions, in: pageRect)
            for session in sessions {
                ctx.beginPage()
                SessionPDF.drawPage(session, in: pageRect)
            }
        }

        // Re-open with PDFKit and add link annotations on the TOC page so each
        // row jumps to the corresponding session page.
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("luche_sessions_\(filenameStamp()).pdf")
        if let doc = PDFDocument(url: intermediateURL),
           let tocPage = doc.page(at: 0) {
            for (i, topLeftRect) in rowRectsTopLeft.enumerated() {
                guard i + 1 < doc.pageCount, let dest = doc.page(at: i + 1) else { continue }
                let pdfRect = CGRect(
                    x: topLeftRect.minX,
                    y: pageRect.height - topLeftRect.maxY,
                    width: topLeftRect.width,
                    height: topLeftRect.height
                )
                let annot = PDFAnnotation(bounds: pdfRect, forType: .link, withProperties: nil)
                annot.color = .clear
                annot.action = PDFActionGoTo(destination: PDFDestination(page: dest, at: CGPoint(x: 0, y: pageRect.height)))
                tocPage.addAnnotation(annot)
            }
            if !doc.write(to: finalURL) {
                throw NSError(
                    domain: "SessionExport", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not write final PDF"]
                )
            }
            try? FileManager.default.removeItem(at: intermediateURL)
            return finalURL
        }
        // Couldn't add links — return the intermediate as-is.
        try? FileManager.default.moveItem(at: intermediateURL, to: finalURL)
        return finalURL
    }

    // MARK: TOC

    /// Draws the contents page. Returns one rect per row in *top-left* page
    /// coords — the caller turns these into PDF link annotations.
    @discardableResult
    private static func drawTOC(sessions: [Session], in rect: CGRect) -> [CGRect] {
        let margin: CGFloat = 50
        var y: CGFloat = margin

        ("Sessions (\(sessions.count))" as NSString).draw(
            at: CGPoint(x: margin, y: y),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: UIColor.lucheInk,
            ]
        )
        y += 46

        let exportedAt = exportedAtString()
        (exportedAt as NSString).draw(
            at: CGPoint(x: margin, y: y),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.darkGray,
            ]
        )
        y += 28

        // Column layout. "Score" + "Detail" are evaluation-aware (FoG shows
        // % fog + fog-frame count; regression heads show the 0-1 score + band)
        // so a mixed export doesn't pin everything to zero like a hardcoded
        // "Fog %" column would.
        let columns: [(String, CGFloat, NSTextAlignment)] = [
            ("Title",      150, .left),
            ("Type",        90, .left),
            ("Date",        95, .left),
            ("Time",        55, .left),
            ("Duration",    65, .left),
            ("Frames",      55, .right),
            ("Score",       60, .right),
            ("Detail",      60, .right),
            ("Page",        50, .right),
        ]
        let tableWidth = columns.reduce(0) { $0 + $1.1 }
        let tableX = margin
        let headerY = y

        // Header
        var x = tableX
        for (title, width, align) in columns {
            drawCell(title, in: CGRect(x: x, y: headerY, width: width, height: 18),
                     align: align, attrs: [
                        .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: UIColor.darkGray,
                     ])
            x += width
        }
        y += 22

        // Header underline
        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.setStrokeColor(UIColor.lightGray.cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: tableX, y: y - 4))
            ctx.addLine(to: CGPoint(x: tableX + tableWidth, y: y - 4))
            ctx.strokePath()
        }

        // Rows
        let rowHeight: CGFloat = 24
        var rowRects: [CGRect] = []
        let dateF = DateFormatter()
        dateF.dateFormat = "MMM d, yyyy"
        let timeF = DateFormatter()
        timeF.dateFormat = "HH:mm"

        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.lucheInk,
        ]

        for (i, session) in sessions.enumerated() {
            let durMin = Int(session.duration) / 60
            let durSec = Int(session.duration) % 60
            let pageNum = i + 2  // TOC is page 1 (index 0); session pages start at index 1 → "page 2"

            let evaluation = session.effectiveEvaluation
            let scoreText: String
            let detailText: String
            if evaluation.headlinesFogPct {
                scoreText = String(format: "%.1f%%", session.fogPct)
                detailText = "\(session.fogCount) fog"
            } else {
                scoreText = String(format: "%.2f", session.updrsScore)
                detailText = session.updrsBand
            }

            let values: [String] = [
                session.displayTitle,
                evaluation.displayName,
                dateF.string(from: session.startedAt),
                timeF.string(from: session.startedAt),
                "\(durMin)m \(durSec)s",
                "\(session.totalFrames)",
                scoreText,
                detailText,
                "\(pageNum)",
            ]

            var x = tableX
            for ((_, width, align), value) in zip(columns, values) {
                let attrs: [NSAttributedString.Key: Any]
                if align == .right && width <= 80 {
                    // page number gets the link-blue tint to suggest "tap me"
                    let isLast = (value == "\(pageNum)") && (width == 50)
                    if isLast {
                        attrs = [
                            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                            .foregroundColor: UIColor.systemBlue,
                        ]
                    } else {
                        attrs = cellAttrs
                    }
                } else {
                    attrs = cellAttrs
                }
                drawCell(value, in: CGRect(x: x, y: y + 4, width: width, height: rowHeight - 6),
                         align: align, attrs: attrs)
                x += width
            }

            // Whole row is the clickable target.
            rowRects.append(CGRect(x: tableX, y: y, width: tableWidth, height: rowHeight))

            // Faint row separator
            if let ctx = UIGraphicsGetCurrentContext() {
                ctx.setStrokeColor(UIColor.lightGray.withAlphaComponent(0.3).cgColor)
                ctx.setLineWidth(0.3)
                ctx.move(to: CGPoint(x: tableX, y: y + rowHeight))
                ctx.addLine(to: CGPoint(x: tableX + tableWidth, y: y + rowHeight))
                ctx.strokePath()
            }
            y += rowHeight

            // If we run out of vertical space, stop drawing more rows. The PDF
            // would otherwise overflow the page; we don't paginate the TOC.
            if y > rect.height - margin - 30 { break }
        }

        // Footer
        let footer = "Luche"
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor.lightGray,
        ]
        let footerSize = (footer as NSString).size(withAttributes: footerAttrs)
        (footer as NSString).draw(
            at: CGPoint(x: rect.width - margin - footerSize.width,
                        y: rect.height - margin / 2 - footerSize.height),
            withAttributes: footerAttrs
        )

        return rowRects
    }

    private static func drawCell(_ text: String, in rect: CGRect,
                                 align: NSTextAlignment,
                                 attrs: [NSAttributedString.Key: Any]) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingTail
        var merged = attrs
        merged[.paragraphStyle] = para
        (text as NSString).draw(in: rect, withAttributes: merged)
    }

    // MARK: Helpers

    private static func filenameStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.string(from: Date())
    }

    private static func exportedAtString() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Exported " + f.string(from: Date())
    }

    private static func combinedPDFFormat(count: Int) -> UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Luche — \(count) sessions",
            kCGPDFContextCreator as String: "Luche",
        ]
        return format
    }
}
