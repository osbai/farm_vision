import Foundation
import Combine
import CoreMotion

final class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()

    @Published var pitch: Double?
    @Published var roll: Double?
    @Published var yaw: Double?
    @Published var gravityX: Double?
    @Published var gravityY: Double?
    @Published var gravityZ: Double?
    @Published var userAccelX: Double?
    @Published var userAccelY: Double?
    @Published var userAccelZ: Double?
    @Published var relativeAltitude: Double?
    @Published var pressure: Double?
    @Published var isStationary: Bool = true

    private var accelMagnitudeBuffer: [Double] = []
    private let stationaryWindowSize = 50  // ~0.5s at 100Hz
    private let stationaryThreshold = 0.05 // m/s²

    init() {
        queue.name = "com.farmcapture.motion"
        queue.maxConcurrentOperationCount = 1
    }

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            print("Device motion not available")
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0 // 100 Hz
        motionManager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: queue) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    print("Motion error: \(error.localizedDescription)")
                }
                return
            }
            DispatchQueue.main.async {
                self.pitch = motion.attitude.pitch
                self.roll = motion.attitude.roll
                self.yaw = motion.attitude.yaw
                self.gravityX = motion.gravity.x
                self.gravityY = motion.gravity.y
                self.gravityZ = motion.gravity.z
                let ax = motion.userAcceleration.x
                let ay = motion.userAcceleration.y
                let az = motion.userAcceleration.z
                self.userAccelX = ax
                self.userAccelY = ay
                self.userAccelZ = az

                let mag = sqrt(ax * ax + ay * ay + az * az)
                self.accelMagnitudeBuffer.append(mag)
                if self.accelMagnitudeBuffer.count > self.stationaryWindowSize {
                    self.accelMagnitudeBuffer.removeFirst(self.accelMagnitudeBuffer.count - self.stationaryWindowSize)
                }
                if self.accelMagnitudeBuffer.count == self.stationaryWindowSize {
                    self.isStationary = self.accelMagnitudeBuffer.allSatisfy { $0 < self.stationaryThreshold }
                }
            }
        }

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
                guard let self = self, let data = data else { return }
                DispatchQueue.main.async {
                    self.relativeAltitude = data.relativeAltitude.doubleValue
                    self.pressure = data.pressure.doubleValue
                }
            }
        }
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }
}
