import Foundation
import CoreLocation
import AVFoundation
import Accelerate
import UIKit

final class CaptureSession {
    let sessionId: String
    let sessionDirectory: URL
    private(set) var frameCount: Int = 0
    private(set) var startTime: Date?
    private(set) var totalDistance: Double = 0.0
    private var lastLocation: CLLocation?
    private var snapshots: [SensorSnapshot] = []
    private let queue = DispatchQueue(label: "com.farmcapture.session")

    init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())
        self.sessionId = "session_\(stamp)"

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.sessionDirectory = docs.appendingPathComponent(sessionId)

        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    var duration: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func start() {
        startTime = Date()
        frameCount = 0
        totalDistance = 0
        lastLocation = nil
        snapshots = []
    }

    func nextFrameId() -> Int {
        queue.sync {
            let id = frameCount
            frameCount += 1
            return id
        }
    }

    func updateDistance(with location: CLLocation, isStationary: Bool) {
        queue.sync {
            if let last = lastLocation {
                let delta = location.distance(from: last)
                if !isStationary && delta > 2.0 && location.horizontalAccuracy < 10.0 {
                    totalDistance += delta
                }
            }
            lastLocation = location
        }
    }

    func saveImage(_ imageData: Data, frameId: Int) -> String? {
        let filename = String(format: "frame_%05d.jpg", frameId)
        let fileURL = sessionDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL)
            return filename
        } catch {
            print("Failed to save image: \(error)")
            return nil
        }
    }

    func saveDepthMap(_ depthData: AVDepthData, frameId: Int) -> (depthPath: String, confidencePath: String?)? {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthBuffer = converted.depthDataMap

        guard let pngData = depthBufferToPng16(depthBuffer) else {
            print("Failed to convert depth buffer to PNG")
            return nil
        }

        let depthFilename = String(format: "depth_%05d.png", frameId)
        let depthURL = sessionDirectory.appendingPathComponent(depthFilename)
        do {
            try pngData.write(to: depthURL)
        } catch {
            print("Failed to save depth map: \(error)")
            return nil
        }

        let confidenceFilename: String? = nil
        if #available(iOS 14.0, *),
           let confidenceMap = converted.cameraCalibrationData {
            // Confidence data is not directly on cameraCalibrationData;
            // it is available only when using AVDepthData from photo or
            // certain pipeline configurations. We skip if unavailable.
            _ = confidenceMap
        }

        return (depthPath: depthFilename, confidencePath: confidenceFilename)
    }

    func saveDepthBuffer(_ depthBuffer: CVPixelBuffer, frameId: Int) -> String? {
        guard let pngData = depthBufferToPng16(depthBuffer) else {
            print("Failed to convert depth buffer to PNG")
            return nil
        }

        let filename = String(format: "depth_%05d.png", frameId)
        let fileURL = sessionDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: fileURL)
            return filename
        } catch {
            print("Failed to save depth buffer: \(error)")
            return nil
        }
    }

    func saveConfidenceMap(_ confidenceBuffer: CVPixelBuffer, frameId: Int) -> String? {
        CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(confidenceBuffer)
        let height = CVPixelBufferGetHeight(confidenceBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceBuffer) else { return nil }
        let uint8Pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceBuffer)

        var scaledPixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let rawValue = uint8Pointer[y * bytesPerRow + x]
                switch rawValue {
                case 0: scaledPixels[y * width + x] = 0
                case 1: scaledPixels[y * width + x] = 127
                default: scaledPixels[y * width + x] = 255
                }
            }
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let provider = CGDataProvider(data: Data(scaledPixels) as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 8,
                                    bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }

        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else { return nil }

        let filename = String(format: "confidence_%05d.png", frameId)
        let fileURL = sessionDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: fileURL)
            return filename
        } catch {
            print("Failed to save confidence map: \(error)")
            return nil
        }
    }

    func saveWorldMap(_ mapData: Data) -> String? {
        let filename = "world_map.arworldmap"
        let fileURL = sessionDirectory.appendingPathComponent(filename)
        do {
            try mapData.write(to: fileURL)
            return filename
        } catch {
            print("Failed to save world map: \(error)")
            return nil
        }
    }

    func savePointCloud(vertices: [(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8)]) -> String? {
        let filename = "pointcloud.ply"
        let fileURL = sessionDirectory.appendingPathComponent(filename)

        var ply = "ply\n"
        ply += "format ascii 1.0\n"
        ply += "element vertex \(vertices.count)\n"
        ply += "property float x\n"
        ply += "property float y\n"
        ply += "property float z\n"
        ply += "property uchar red\n"
        ply += "property uchar green\n"
        ply += "property uchar blue\n"
        ply += "end_header\n"

        for v in vertices {
            ply += "\(v.x) \(v.y) \(v.z) \(v.r) \(v.g) \(v.b)\n"
        }

        do {
            try ply.write(to: fileURL, atomically: true, encoding: .utf8)
            return filename
        } catch {
            print("Failed to save point cloud: \(error)")
            return nil
        }
    }

    func saveMesh(vertices: [(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8)],
                  faces: [(v0: Int, v1: Int, v2: Int)]) -> String? {
        let filename = "mesh.ply"
        let fileURL = sessionDirectory.appendingPathComponent(filename)

        var ply = "ply\n"
        ply += "format ascii 1.0\n"
        ply += "element vertex \(vertices.count)\n"
        ply += "property float x\n"
        ply += "property float y\n"
        ply += "property float z\n"
        ply += "property uchar red\n"
        ply += "property uchar green\n"
        ply += "property uchar blue\n"
        ply += "element face \(faces.count)\n"
        ply += "property list uchar int vertex_indices\n"
        ply += "end_header\n"

        for v in vertices {
            ply += "\(v.x) \(v.y) \(v.z) \(v.r) \(v.g) \(v.b)\n"
        }

        for f in faces {
            ply += "3 \(f.v0) \(f.v1) \(f.v2)\n"
        }

        do {
            try ply.write(to: fileURL, atomically: true, encoding: .utf8)
            print("[Mesh] Saved mesh to \(filename): \(vertices.count) vertices, \(faces.count) faces")
            return filename
        } catch {
            print("Failed to save mesh: \(error)")
            return nil
        }
    }

    private func depthBufferToPng16(_ pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let floatPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.size

        var uint16Pixels = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let depthMeters = floatPointer[y * floatsPerRow + x]
                let clamped = max(0.0, min(depthMeters, 10.0))
                let normalized = clamped / 10.0
                uint16Pixels[y * width + x] = UInt16(normalized * 65535.0)
            }
        }

        let bitmapInfo: CGBitmapInfo = [CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         CGBitmapInfo.byteOrder16Big]
        guard let provider = CGDataProvider(data: Data(bytes: &uint16Pixels,
                                                        count: uint16Pixels.count * 2) as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 16,
                                    bitsPerPixel: 16,
                                    bytesPerRow: width * 2,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.pngData()
    }

    func addSnapshot(_ snapshot: SensorSnapshot) {
        queue.sync {
            snapshots.append(snapshot)
        }
    }

    func saveMetadata() {
        queue.sync {
            let fileURL = sessionDirectory.appendingPathComponent("session_metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(snapshots)
                try data.write(to: fileURL)
            } catch {
                print("Failed to save metadata: \(error)")
            }
        }
    }

    var snapshotCount: Int {
        queue.sync { snapshots.count }
    }
}
