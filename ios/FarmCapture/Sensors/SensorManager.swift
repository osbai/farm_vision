import Foundation
import ARKit
import CoreLocation
import CoreVideo
import Combine
import simd

final class SensorManager: ObservableObject {
    let locationManager = LocationManager()
    let motionManager = MotionManager()
    let arkitManager = ARKitManager()

    @Published var isSweeping = false
    @Published var framesCaptured: Int = 0
    @Published var sessionDuration: TimeInterval = 0
    @Published var distanceWalked: Double = 0
    @Published var currentFPS: Double = 0
    @Published var isLiDARAvailable = false
    @Published var trackingState: String = "notAvailable"
    @Published var worldMappingStatus: String = "notAvailable"
    var latestImageData: Data?
    var latestDepthBuffer: CVPixelBuffer?

    private(set) var captureSession: CaptureSession?
    private let capturePolicy = AdaptiveCapturePolicy()
    private let processingQueue = DispatchQueue(label: "com.farmcapture.processing")
    private var lastCaptureTime: TimeInterval = 0
    private var previousState = AdaptiveCapturePolicy.SensorState()
    private var fpsTimestamps: [TimeInterval] = []
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        arkitManager.delegate = self
        arkitManager.$isLiDARAvailable
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLiDARAvailable)
        arkitManager.$trackingState
            .receive(on: DispatchQueue.main)
            .assign(to: &$trackingState)
        arkitManager.$worldMappingStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$worldMappingStatus)
    }

    func setup() {
        locationManager.requestPermission()
        arkitManager.configure()
    }

    func startSensors() {
        locationManager.startUpdates()
        motionManager.startUpdates()
        arkitManager.start()
    }

    func stopSensors() {
        locationManager.stopUpdates()
        motionManager.stopUpdates()
        arkitManager.stop()
    }

    func startSweep() {
        let session = CaptureSession()
        session.start()
        captureSession = session
        lastCaptureTime = 0
        previousState = AdaptiveCapturePolicy.SensorState()
        fpsTimestamps = []

        startSensors()

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sessionDuration = session.duration
            self.distanceWalked = session.totalDistance
            self.framesCaptured = session.snapshotCount
        }

        isSweeping = true
    }

    func stopSweep() {
        isSweeping = false
        durationTimer?.invalidate()
        durationTimer = nil

        captureSession?.saveMetadata()

        captureSession = nil
        framesCaptured = 0
        sessionDuration = 0
        distanceWalked = 0
        currentFPS = 0
    }

    func captureManualFrame(imageData: Data) {
        let session = captureSession ?? createOneOffSession()
        processingQueue.async { [weak self] in
            self?.processFrame(
                imageData: imageData,
                depthBuffer: nil,
                confidenceBuffer: nil,
                pose: nil,
                intrinsics: nil,
                trackingState: nil,
                trackingStateReason: nil,
                worldMappingStatus: nil,
                trigger: "manual",
                session: session
            )
        }
    }

    private func createOneOffSession() -> CaptureSession {
        let session = CaptureSession()
        session.start()
        return session
    }

    // MARK: - Snapshot Building

    private func buildSnapshot(frameId: Int,
                               trigger: String,
                               imagePath: String?,
                               depthPath: String?,
                               depthWidth: Int?,
                               depthHeight: Int?,
                               confidencePath: String?,
                               poseMatrix: [Float]?,
                               intrinsics: [Float]?,
                               trackingState: String?,
                               trackingStateReason: String?,
                               worldMappingStatus: String?) -> SensorSnapshot {
        SensorSnapshot(
            frameId: frameId,
            timestamp: Date().timeIntervalSince1970,
            trigger: trigger,
            latitude: locationManager.latitude,
            longitude: locationManager.longitude,
            altitude: locationManager.altitude,
            gpsAccuracy: locationManager.gpsAccuracy,
            speed: locationManager.speed,
            course: locationManager.course,
            heading: locationManager.heading,
            headingAccuracy: locationManager.headingAccuracy,
            pitch: motionManager.pitch,
            roll: motionManager.roll,
            yaw: motionManager.yaw,
            gravityX: motionManager.gravityX,
            gravityY: motionManager.gravityY,
            gravityZ: motionManager.gravityZ,
            userAccelX: motionManager.userAccelX,
            userAccelY: motionManager.userAccelY,
            userAccelZ: motionManager.userAccelZ,
            relativeAltitude: motionManager.relativeAltitude,
            pressure: motionManager.pressure,
            imagePath: imagePath,
            hasDepth: depthPath != nil,
            depthPath: depthPath,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            confidencePath: confidencePath,
            poseMatrix: poseMatrix,
            intrinsics: intrinsics,
            trackingState: trackingState,
            trackingStateReason: trackingStateReason,
            worldMappingStatus: worldMappingStatus
        )
    }

    // MARK: - Frame Processing

    private func processFrame(imageData: Data,
                              depthBuffer: CVPixelBuffer?,
                              confidenceBuffer: CVPixelBuffer?,
                              pose: simd_float4x4?,
                              intrinsics: simd_float3x3?,
                              trackingState: String?,
                              trackingStateReason: String?,
                              worldMappingStatus: String?,
                              trigger: String,
                              session: CaptureSession) {
        let frameId = session.nextFrameId()
        let imagePath = session.saveImage(imageData, frameId: frameId)

        if let loc = locationManager.lastLocation {
            session.updateDistance(with: loc, isStationary: motionManager.isStationary)
        }

        var depthPath: String?
        var depthWidth: Int?
        var depthHeight: Int?
        var confidencePath: String?

        if let depth = depthBuffer {
            depthPath = session.saveDepthBuffer(depth, frameId: frameId)
            depthWidth = CVPixelBufferGetWidth(depth)
            depthHeight = CVPixelBufferGetHeight(depth)
        }

        if let confidence = confidenceBuffer {
            confidencePath = session.saveConfidenceMap(confidence, frameId: frameId)
        }

        let poseArray = pose.map { flattenColumnMajor4x4($0) }
        let intrinsicsArray = intrinsics.map { flattenColumnMajor3x3($0) }

        let snapshot = buildSnapshot(
            frameId: frameId,
            trigger: trigger,
            imagePath: imagePath,
            depthPath: depthPath,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            confidencePath: confidencePath,
            poseMatrix: poseArray,
            intrinsics: intrinsicsArray,
            trackingState: trackingState,
            trackingStateReason: trackingStateReason,
            worldMappingStatus: worldMappingStatus
        )
        session.addSnapshot(snapshot)

        DispatchQueue.main.async { [weak self] in
            self?.framesCaptured = session.snapshotCount
        }
    }

    // MARK: - simd → [Float] Conversions

    private func flattenColumnMajor4x4(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }

    private func flattenColumnMajor3x3(_ m: simd_float3x3) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z,
         m.columns.1.x, m.columns.1.y, m.columns.1.z,
         m.columns.2.x, m.columns.2.y, m.columns.2.z]
    }

    // MARK: - Tracking State Parsing

    private func parseTrackingState(_ state: Any) -> (state: String, reason: String?) {
        guard let arState = state as? Int else { return ("notAvailable", nil) }
        switch arState {
        case 0: return ("notAvailable", nil)
        case 1: return ("limited", nil)
        case 2: return ("normal", nil)
        default: return ("notAvailable", nil)
        }
    }

    private func updateFPS(timestamp: TimeInterval) {
        fpsTimestamps.append(timestamp)
        let cutoff = timestamp - 1.0
        fpsTimestamps.removeAll { $0 < cutoff }
        DispatchQueue.main.async { [weak self] in
            self?.currentFPS = Double(self?.fpsTimestamps.count ?? 0)
        }
    }
}

// MARK: - ARKitManagerDelegate

extension SensorManager: ARKitManagerDelegate {
    func arkitManager(_ manager: ARKitManager, didUpdate frameData: ARFrameData) {
        latestImageData = frameData.imageData
        latestDepthBuffer = frameData.depthMap

        guard isSweeping, let session = captureSession else { return }

        let currentState = AdaptiveCapturePolicy.SensorState(
            location: locationManager.lastLocation,
            heading: locationManager.heading,
            pitch: motionManager.pitch,
            isStationary: motionManager.isStationary
        )

        let timeSinceLast = lastCaptureTime == 0 ? .infinity : frameData.timestamp - lastCaptureTime
        let decision = capturePolicy.shouldCapture(
            timeSinceLast: timeSinceLast,
            previousState: previousState,
            currentState: currentState
        )

        guard decision.shouldCapture else { return }

        lastCaptureTime = frameData.timestamp
        previousState = currentState
        updateFPS(timestamp: frameData.timestamp)

        let trackingState = trackingStateString(frameData.trackingState)
        let trackingReason = trackingReasonString(frameData.trackingState)
        let mappingStatus = worldMappingStatusString(frameData.worldMappingStatus)

        processingQueue.async { [weak self] in
            self?.processFrame(
                imageData: frameData.imageData,
                depthBuffer: frameData.depthMap,
                confidenceBuffer: frameData.confidenceMap,
                pose: frameData.pose,
                intrinsics: frameData.intrinsics,
                trackingState: trackingState,
                trackingStateReason: trackingReason,
                worldMappingStatus: mappingStatus,
                trigger: decision.trigger,
                session: session
            )
        }
    }

    // MARK: - ARKit Enum → String Mapping

    private func trackingStateString(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .normal: return "normal"
        @unknown default: return "notAvailable"
        }
    }

    private func trackingReasonString(_ state: ARCamera.TrackingState) -> String? {
        switch state {
        case .limited(let reason):
            switch reason {
            case .initializing: return "initializing"
            case .relocalizing: return "relocalizing"
            case .excessiveMotion: return "excessiveMotion"
            case .insufficientFeatures: return "insufficientFeatures"
            @unknown default: return "unknown"
            }
        default:
            return nil
        }
    }

    private func worldMappingStatusString(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "notAvailable"
        }
    }
}
