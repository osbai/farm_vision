import Foundation
import CoreLocation

struct AdaptiveCapturePolicy {
    private let defaultInterval: TimeInterval = 0.2    // 5 fps
    private let minInterval: TimeInterval = 0.1         // 10 fps max
    private let idleInterval: TimeInterval = 1.0        // 1 fps when still

    private let positionBoostThreshold: Double = 0.15   // meters
    private let headingBoostThreshold: Double = 5.0     // degrees
    private let pitchBoostThreshold: Double = 10.0      // degrees (converted to radians internally)

    private let positionIdleThreshold: Double = 0.05    // meters
    private let headingIdleThreshold: Double = 2.0      // degrees

    struct SensorState {
        var location: CLLocation?
        var heading: Double?
        var pitch: Double?
        var isStationary: Bool = false
    }

    func shouldCapture(
        timeSinceLast: TimeInterval,
        previousState: SensorState,
        currentState: SensorState
    ) -> (shouldCapture: Bool, trigger: String) {
        // Never capture faster than 10 fps
        if timeSinceLast < minInterval {
            return (false, "")
        }

        let positionDelta = positionDeltaMeters(from: previousState.location, to: currentState.location)
        let headingDelta = angleDelta(from: previousState.heading, to: currentState.heading)
        let pitchDelta = pitchDeltaDegrees(from: previousState.pitch, to: currentState.pitch)

        // Boost: capture sooner on significant movement
        if timeSinceLast >= minInterval {
            if positionDelta > positionBoostThreshold {
                return (true, "position")
            }
            if headingDelta > headingBoostThreshold {
                return (true, "heading")
            }
            if pitchDelta > pitchBoostThreshold {
                return (true, "pitch")
            }
        }

        // Idle: drop to 1 fps if standing still (use accelerometer-based detection)
        let isIdle = currentState.isStationary || (positionDelta < positionIdleThreshold && headingDelta < headingIdleThreshold)
        if isIdle {
            if timeSinceLast >= idleInterval {
                return (true, "time")
            }
            return (false, "")
        }

        // Default: 5 fps
        if timeSinceLast >= defaultInterval {
            return (true, "time")
        }

        return (false, "")
    }

    private func positionDeltaMeters(from prev: CLLocation?, to curr: CLLocation?) -> Double {
        guard let prev = prev, let curr = curr else { return 0 }
        return curr.distance(from: prev)
    }

    private func angleDelta(from prev: Double?, to curr: Double?) -> Double {
        guard let prev = prev, let curr = curr else { return 0 }
        var delta = abs(curr - prev)
        if delta > 180 { delta = 360 - delta }
        return delta
    }

    private func pitchDeltaDegrees(from prev: Double?, to curr: Double?) -> Double {
        guard let prev = prev, let curr = curr else { return 0 }
        // pitch is in radians, convert delta to degrees
        return abs(curr - prev) * (180.0 / .pi)
    }
}
