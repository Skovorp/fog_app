import Accelerate
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Image preprocessing. Each evaluation has its own (modelInputFrames,
/// frameSubsampleStep, modelSpatialSize) tuple — see Evaluation.swift. The
/// 64-frame capture buffer is constant; this code picks the right subset and
/// resizes it to whatever the matching mlpackage expects.
enum Preprocess {
    static let mean: SIMD3<Float> = .init(0.485, 0.456, 0.406)
    static let std: SIMD3<Float> = .init(0.229, 0.224, 0.225)

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Pack `captureFramesPerChunk` raw camera frames into one MLMultiArray
    /// sized (1, modelInputFrames, 3, modelSpatialSize, modelSpatialSize) for
    /// the given evaluation.
    static func buildModelInput(from buffers: [CVPixelBuffer], for evaluation: Evaluation) throws -> MLMultiArray {
        precondition(buffers.count == evaluation.captureFramesPerChunk,
                     "Expected \(evaluation.captureFramesPerChunk) frames, got \(buffers.count)")

        let inputFrames = evaluation.modelInputFrames
        let step = evaluation.frameSubsampleStep
        let size = evaluation.modelSpatialSize

        let arr = try MLMultiArray(
            shape: [1, NSNumber(value: inputFrames), 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        )
        let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: arr.count)
        let perFrame = 3 * size * size

        for i in 0..<inputFrames {
            let frame = stretchResize(buffers[i * step], to: size)
            try writeNormalizedRGB(frame, into: ptr.advanced(by: i * perFrame), size: size)
        }

        return arr
    }

    /// Anamorphic resize the full frame to `size × size` (no crop, no padding).
    /// Mirrors `feral.dataset`'s training-time preprocessing.
    private static func stretchResize(_ buffer: CVPixelBuffer, to size: Int) -> CGImage {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)

        let ci = CIImage(cvPixelBuffer: buffer)
        let scaled = ci.transformed(by: CGAffineTransform(
            scaleX: CGFloat(size) / CGFloat(w),
            y: CGFloat(size) / CGFloat(h)
        ))

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let cg = ciContext.createCGImage(scaled, from: rect) else {
            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: 4 * size, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            return ctx.makeImage()!
        }
        return cg
    }

    private static func writeNormalizedRGB(_ image: CGImage, into dst: UnsafeMutablePointer<Float32>, size: Int) throws {
        let bytesPerRow = 4 * size
        var raw = [UInt8](repeating: 0, count: bytesPerRow * size)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &raw, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "FeralDemo.Preprocess", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create RGBA context"])
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        let plane = size * size
        let invStd = SIMD3<Float>(1.0 / std.x, 1.0 / std.y, 1.0 / std.z)
        for y in 0..<size {
            for x in 0..<size {
                let p = (y * size + x) * 4
                let r = (Float(raw[p + 0]) / 255.0 - mean.x) * invStd.x
                let g = (Float(raw[p + 1]) / 255.0 - mean.y) * invStd.y
                let b = (Float(raw[p + 2]) / 255.0 - mean.z) * invStd.z
                let idx = y * size + x
                dst[0 * plane + idx] = r
                dst[1 * plane + idx] = g
                dst[2 * plane + idx] = b
            }
        }
    }
}
