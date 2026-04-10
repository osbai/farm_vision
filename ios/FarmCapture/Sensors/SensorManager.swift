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
    let mapManager = MapManager()
    let gpsFusion = GPSSLAMFusion()
    let relocalizationEngine: RelocalizationEngine

    @Published var isSweeping = false
    @Published var mappingMode: Bool = false
    @Published var fusionStatus: String = "Idle"
    @Published var mapSaved: Bool = false
    @Published var framesCaptured: Int = 0
    @Published var sessionDuration: TimeInterval = 0
    @Published var distanceWalked: Double = 0
    @Published var currentFPS: Double = 0
    @Published var isLiDARAvailable = false
    @Published var trackingState: String = "notAvailable"
    @Published var worldMappingStatus: String = "notAvailable"
    var latestImageData: Data?
    var latestDepthBuffer: CVPixelBuffer?
    private var pointCloudVertices: [(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8)] = []
    private var mappingFrameCounter = 0

    private(set) var captureSession: CaptureSession?
    private let capturePolicy = AdaptiveCapturePolicy()
    private let processingQueue = DispatchQueue(label: "com.farmcapture.processing")
    private var lastCaptureTime: TimeInterval = 0
    private var previousState = AdaptiveCapturePolicy.SensorState()
    private var fpsTimestamps: [TimeInterval] = []
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        relocalizationEngine = RelocalizationEngine(mapManager: mapManager)
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
        gpsFusion.$fusionStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$fusionStatus)
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

    func startMappingSweep() {
        mappingMode = true
        pointCloudVertices = []
        mappingFrameCounter = 0
        startSweep()
    }

    func stopMappingSweep() {
        arkitManager.getCurrentWorldMap { [weak self] worldMap in
            guard let self = self, let map = worldMap else { return }
            let mapData = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            if let data = mapData {
                _ = self.captureSession?.saveWorldMap(data)

                if let lat = self.locationManager.latitude, let lon = self.locationManager.longitude {
                    let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    let bounds = self.computeSessionBounds()
                    let _ = self.mapManager.saveWorldMap(data, center: center, bounds: bounds,
                                                          frameCount: self.captureSession?.snapshotCount ?? 0)
                }
            }

            if !self.pointCloudVertices.isEmpty {
                let _ = self.captureSession?.savePointCloud(vertices: self.pointCloudVertices)
            }

            DispatchQueue.main.async {
                self.mapSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.mapSaved = false }
            }

            self.mappingMode = false
            self.stopSweep()
        }
    }

    func startRelocalization() {
        guard let loc = locationManager.lastLocation else { return }
        relocalizationEngine.startRelocalization(arkitManager: arkitManager, currentLocation: loc)
    }

    func stopSweep() {
        isSweeping = false
        durationTimer?.invalidate()
        durationTimer = nil

        // Save ARKit mesh reconstruction if available
        if let session = captureSession {
            saveARKitMesh(to: session)
        }

        captureSession?.saveMetadata()

        captureSession = nil
        framesCaptured = 0
        sessionDuration = 0
        distanceWalked = 0
        currentFPS = 0
    }

    // MARK: - ARKit Mesh Extraction

    private func saveARKitMesh(to session: CaptureSession) {
        let anchors = arkitManager.arSession.currentFrame?.anchors ?? []
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }

        guard !meshAnchors.isEmpty else {
            print("[Mesh] No mesh anchors available")
            return
        }

        var allVertices: [(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8)] = []
        var allFaces: [(v0: Int, v1: Int, v2: Int)] = []
        var vertexOffset = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            // Extract vertices and transform to world space
            let vertexBuffer = geometry.vertices
            for i in 0..<vertexBuffer.count {
                let vertexPointer = vertexBuffer.buffer.contents().advanced(by: vertexBuffer.offset + vertexBuffer.stride * i)
                let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee

                let worldPoint = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)

                // Color by height (green for low/ground, brown for higher/plants)
                let height = worldPoint.y
                let r: UInt8, g: UInt8, b: UInt8
                if height < 0.3 {
                    r = 139; g = 119; b = 101  // brown (ground)
                } else if height < 1.0 {
                    r = 34; g = 139; b = 34    // green (low vegetation)
                } else {
                    r = 0; g = 100; b = 0      // dark green (tall vegetation)
                }

                allVertices.append((x: worldPoint.x, y: worldPoint.y, z: worldPoint.z, r: r, g: g, b: b))
            }

            // Extract faces
            let faceBuffer = geometry.faces
            for i in 0..<faceBuffer.count {
                let facePointer = faceBuffer.buffer.contents().advanced(by: faceBuffer.indexCountPerPrimitive * faceBuffer.bytesPerIndex * i)
                let indices = facePointer.assumingMemoryBound(to: UInt32.self)
                allFaces.append((
                    v0: Int(indices[0]) + vertexOffset,
                    v1: Int(indices[1]) + vertexOffset,
                    v2: Int(indices[2]) + vertexOffset
                ))
            }

            vertexOffset += vertexBuffer.count
        }

        print("[Mesh] Extracted \(allVertices.count) vertices, \(allFaces.count) faces from \(meshAnchors.count) anchors")

        // Save as PLY with mesh faces
        let _ = session.saveMesh(vertices: allVertices, faces: allFaces)
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

        if mappingMode, let depth = depthBuffer, let p = pose, let intr = intrinsics {
            mappingFrameCounter += 1
            if mappingFrameCounter % 5 == 0 && pointCloudVertices.count < 500_000 {
                let vertices = unprojectDepthToPoints(depth: depth, pose: p, intrinsics: intr,
                                                       imageData: imageData)
                pointCloudVertices.append(contentsOf: vertices)
            }
        }

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

    private func unprojectDepthToPoints(depth: CVPixelBuffer, pose: simd_float4x4,
                                         intrinsics: simd_float3x3, imageData: Data)
        -> [(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8)] {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }

        let w = CVPixelBufferGetWidth(depth)
        let h = CVPixelBufferGetHeight(depth)
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return [] }
        let floats = base.assumingMemoryBound(to: Float32.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size

        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        var points: [(x: Float, y: Float, z: Float, r: UInt8, g: UInt8, b: UInt8)] = []

        let step = 8
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let d = floats[y * bytesPerRow + x]
                guard d > 0.1 && d < 5.0 else { continue }

                let camX = (Float(x) - cx) * d / fx
                let camY = (Float(y) - cy) * d / fy
                let camZ = d
                let camPoint = simd_float4(camX, -camY, -camZ, 1)

                let worldPoint = pose * camPoint

                points.append((x: worldPoint.x, y: worldPoint.y, z: worldPoint.z,
                               r: 200, g: 200, b: 200))
            }
        }
        return points
    }

    private func computeSessionBounds() -> BoundingBox {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        if let lat = locationManager.latitude, let lon = locationManager.longitude {
            minLat = min(minLat, lat); maxLat = max(maxLat, lat)
            minLon = min(minLon, lon); maxLon = max(maxLon, lon)
        }
        let padding = 0.0005
        return BoundingBox(minLat: minLat - padding, minLon: minLon - padding,
                           maxLat: maxLat + padding, maxLon: maxLon + padding)
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
        latestDepthBuffer = nil

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

        if mappingMode, let loc = locationManager.lastLocation {
            gpsFusion.addObservation(arkitPose: frameData.pose, gpsLocation: loc)
        }

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
