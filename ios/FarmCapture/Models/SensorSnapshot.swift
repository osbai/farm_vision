import Foundation

struct SensorSnapshot: Codable {
    let frameId: Int
    let timestamp: TimeInterval
    let trigger: String  // "time", "position", "heading", "manual"

    // GPS
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let gpsAccuracy: Double?
    let speed: Double?
    let course: Double?

    // Compass
    let heading: Double?
    let headingAccuracy: Double?

    // IMU (Device Motion)
    let pitch: Double?
    let roll: Double?
    let yaw: Double?
    let gravityX: Double?
    let gravityY: Double?
    let gravityZ: Double?
    let userAccelX: Double?
    let userAccelY: Double?
    let userAccelZ: Double?

    // Barometer
    let relativeAltitude: Double?
    let pressure: Double?

    // Camera
    let imagePath: String?

    // LiDAR (optional)
    let hasDepth: Bool
    let depthPath: String?
    let depthWidth: Int?
    let depthHeight: Int?
    let confidencePath: String?

    // ARKit Pose (6-DoF)
    let poseMatrix: [Float]?           // 16-element column-major 4x4 transform
    let intrinsics: [Float]?           // 9-element 3x3 camera intrinsics matrix

    // ARKit Tracking
    let trackingState: String?         // "normal", "limited", "notAvailable"
    let trackingStateReason: String?   // "initializing", "relocalizing", "excessiveMotion", "insufficientFeatures", nil
    let worldMappingStatus: String?    // "notAvailable", "limited", "extending", "mapped"
}
