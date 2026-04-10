import ARKit
import UIKit
import Combine

struct ARFrameData {
    let imageData: Data
    let timestamp: TimeInterval
    let pose: simd_float4x4
    let intrinsics: simd_float3x3
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?
    let trackingState: ARCamera.TrackingState
    let worldMappingStatus: ARFrame.WorldMappingStatus
}

protocol ARKitManagerDelegate: AnyObject {
    func arkitManager(_ manager: ARKitManager, didUpdate frameData: ARFrameData)
}

final class ARKitManager: NSObject, ObservableObject {
    let arSession = ARSession()

    @Published var isRunning = false
    @Published var isLiDARAvailable = false
    @Published var trackingState: String = "notAvailable"
    @Published var worldMappingStatus: String = "notAvailable"

    weak var delegate: ARKitManagerDelegate?
    private let processingQueue = DispatchQueue(label: "com.farmcapture.arkit")
    private let ciContext = CIContext()

    func configure() {
        arSession.delegate = self
        isLiDARAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        if isLiDARAvailable {
            config.frameSemantics = .sceneDepth
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
        }
        arSession.run(config)
        isRunning = true
    }

    func start(with worldMap: ARWorldMap) {
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = worldMap
        if isLiDARAvailable {
            config.frameSemantics = .sceneDepth
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        arSession.pause()
        isRunning = false
    }

    func getCurrentWorldMap(completion: @escaping (ARWorldMap?) -> Void) {
        arSession.getCurrentWorldMap { worldMap, _ in
            completion(worldMap)
        }
    }

    // MARK: - Image Conversion

    private func jpegData(from pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.7) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
    }

    // MARK: - Tracking State Mapping

    private func trackingStateString(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "limited-initializing"
            case .excessiveMotion:
                return "limited-excessiveMotion"
            case .insufficientFeatures:
                return "limited-insufficientFeatures"
            case .relocalizing:
                return "limited-relocalizing"
            @unknown default:
                return "limited-unknown"
            }
        case .normal:
            return "normal"
        }
    }

    private func worldMappingString(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable:
            return "notAvailable"
        case .limited:
            return "limited"
        case .extending:
            return "extending"
        case .mapped:
            return "mapped"
        @unknown default:
            return "unknown"
        }
    }
}

// MARK: - ARSessionDelegate

extension ARKitManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            guard let imageData = self.jpegData(from: frame.capturedImage) else { return }

            let frameData = ARFrameData(
                imageData: imageData,
                timestamp: frame.timestamp,
                pose: frame.camera.transform,
                intrinsics: frame.camera.intrinsics,
                depthMap: frame.sceneDepth?.depthMap,
                confidenceMap: frame.sceneDepth?.confidenceMap,
                trackingState: frame.camera.trackingState,
                worldMappingStatus: frame.worldMappingStatus
            )

            self.delegate?.arkitManager(self, didUpdate: frameData)

            let tsString = self.trackingStateString(frame.camera.trackingState)
            let wmString = self.worldMappingString(frame.worldMappingStatus)
            DispatchQueue.main.async {
                self.trackingState = tsString
                self.worldMappingStatus = wmString
            }
        }
    }
}
