import UIKit
import Accelerate

struct DepthStats {
    let minDepth: Float
    let maxDepth: Float
    let meanDepth: Float
}

enum DepthMapRenderer {

    // MARK: - Public API

    /// Load a 16-bit grayscale PNG depth map and return a colorized UIImage + stats.
    /// Depth values are stored as UInt16 millimeters.
    static func render(depthURL: URL) -> (image: UIImage, stats: DepthStats)? {
        guard let (pixels, width, height) = load16BitPNG(url: depthURL) else { return nil }

        // Encoding: Float32 clamped to [0, 10]m → normalized to [0, 65535] UInt16
        let floatDepths = pixels.map { (Float($0) / 65535.0) * 10.0 }

        let stats = computeStats(floatDepths)
        guard stats.maxDepth > stats.minDepth else { return nil }

        let colorized = applyJetColormap(
            depths: floatDepths,
            width: width,
            height: height,
            minDepth: stats.minDepth,
            maxDepth: stats.maxDepth
        )

        guard let image = colorized else { return nil }
        return (image, stats)
    }

    // MARK: - 16-Bit PNG Loading

    private static func load16BitPNG(url: URL) -> (pixels: [UInt16], width: Int, height: Int)? {
        guard let dataProvider = CGDataProvider(url: url as CFURL),
              let cgImage = CGImage(
                  pngDataProviderSource: dataProvider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let bitsPerPixel = cgImage.bitsPerPixel

        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let bytesPerRow = cgImage.bytesPerRow
        var pixels = [UInt16](repeating: 0, count: width * height)

        if bitsPerPixel == 16 {
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 2
                    let value = UInt16(ptr[offset]) | (UInt16(ptr[offset + 1]) << 8)
                    pixels[y * width + x] = value
                }
            }
        } else if bitsPerPixel == 8 {
            // Fallback: 8-bit depth scaled to 0-255 range
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x
                    pixels[y * width + x] = UInt16(ptr[offset]) * 256
                }
            }
        } else {
            return nil
        }

        return (pixels, width, height)
    }

    // MARK: - Stats

    private static func computeStats(_ depths: [Float]) -> DepthStats {
        let valid = depths.filter { $0 > 0 }
        guard !valid.isEmpty else {
            return DepthStats(minDepth: 0, maxDepth: 0, meanDepth: 0)
        }
        let minVal = valid.min()!
        let maxVal = valid.max()!
        let mean = valid.reduce(0, +) / Float(valid.count)
        return DepthStats(minDepth: minVal, maxDepth: maxVal, meanDepth: mean)
    }

    // MARK: - Jet Colormap

    /// Map a normalized value [0,1] to jet colormap RGB.
    private static func jetColor(_ t: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let clamped = max(0, min(1, t))

        let r: Float
        let g: Float
        let b: Float

        if clamped < 0.125 {
            r = 0; g = 0; b = 0.5 + clamped * 4
        } else if clamped < 0.375 {
            r = 0; g = (clamped - 0.125) * 4; b = 1
        } else if clamped < 0.625 {
            r = (clamped - 0.375) * 4; g = 1; b = 1 - (clamped - 0.375) * 4
        } else if clamped < 0.875 {
            r = 1; g = 1 - (clamped - 0.625) * 4; b = 0
        } else {
            r = 1 - (clamped - 0.875) * 4; g = 0; b = 0
        }

        return (
            UInt8(max(0, min(255, r * 255))),
            UInt8(max(0, min(255, g * 255))),
            UInt8(max(0, min(255, b * 255)))
        )
    }

    private static func applyJetColormap(
        depths: [Float],
        width: Int,
        height: Int,
        minDepth: Float,
        maxDepth: Float
    ) -> UIImage? {
        let range = maxDepth - minDepth
        var rgbaPixels = [UInt8](repeating: 0, count: width * height * 4)

        for i in 0..<depths.count {
            let depth = depths[i]
            if depth <= 0 {
                // Invalid depth → transparent black
                rgbaPixels[i * 4] = 0
                rgbaPixels[i * 4 + 1] = 0
                rgbaPixels[i * 4 + 2] = 0
                rgbaPixels[i * 4 + 3] = 128
            } else {
                let normalized = (depth - minDepth) / range
                let (r, g, b) = jetColor(normalized)
                rgbaPixels[i * 4] = r
                rgbaPixels[i * 4 + 1] = g
                rgbaPixels[i * 4 + 2] = b
                rgbaPixels[i * 4 + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rgbaPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let cgImage = context.makeImage() else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
