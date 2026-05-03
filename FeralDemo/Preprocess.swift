import Accelerate
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Image preprocessing for FeralModel.mlpackage.
///
/// Token-reduced inference. We capture a 64-frame video span but only feed
/// every 4th frame into the model (16 inputs at 256×256 → 2,048 self-attention
/// tokens, 4× fewer than the 8,192 of the dense 64-frame variant). The model
/// still emits 64 query tokens (predict_per_item=64), mapped 1:1 to the 64
/// frames of the span downstream — see RESULTS.md "no-pool" config (run_06).
///
/// Matches the re-exported mlpackage's input shape (1, 16, 3, 256, 256). The
/// V-JEPA 2.1 backbone was pretrained at 384², but the encoder's
/// interpolate_rope=True path scales positional encodings to the 16×16 patch
/// grid we get at 256²; some accuracy hit on the head is expected (see
/// RESULTS.md table — within noise of the 384/64f baseline).
enum Preprocess {
    static let modelInputSize: Int = 256
    /// Number of camera frames captured per inference (= the video span).
    static let bufferSize: Int = 64
    /// Feed every Nth frame from the buffer to the model.
    static let chunkStep: Int = 4
    /// Number of frames actually written into the MLMultiArray.
    static let modelFrames: Int = bufferSize / chunkStep  // 16

    static let mean: SIMD3<Float> = .init(0.485, 0.456, 0.406)
    static let std: SIMD3<Float> = .init(0.229, 0.224, 0.225)

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Pack 64 raw camera frames into one MLMultiArray sized (1, modelFrames, 3, modelInputSize, modelInputSize).
    /// Subsamples every `chunkStep`th frame from the buffer.
    static func buildModelInput(from buffers: [CVPixelBuffer]) throws -> MLMultiArray {
        precondition(buffers.count == bufferSize, "Expected \(bufferSize) frames, got \(buffers.count)")

        let arr = try MLMultiArray(
            shape: [1, NSNumber(value: modelFrames), 3, NSNumber(value: modelInputSize), NSNumber(value: modelInputSize)],
            dataType: .float32
        )
        let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: arr.count)
        let perFrame = 3 * modelInputSize * modelInputSize

        for i in 0..<modelFrames {
            let frame = stretchResize(buffers[i * chunkStep], to: modelInputSize)
            try writeNormalizedRGB(frame, into: ptr.advanced(by: i * perFrame))
        }

        return arr
    }

    /// Anamorphic resize the full frame to `size × size` (no crop, no padding).
    /// Matches `feral.dataset` training preprocessing, which resizes the whole
    /// frame to (384, 384) before ImageNet normalization. Earlier versions did
    /// a square center-crop here, which threw away ~⅓ of the field of view and
    /// produced systematically OOD inputs.
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

    private static func writeNormalizedRGB(_ image: CGImage, into dst: UnsafeMutablePointer<Float32>) throws {
        let size = modelInputSize
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
