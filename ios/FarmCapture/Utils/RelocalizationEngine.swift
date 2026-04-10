import Foundation
import ARKit
import CoreLocation
import Combine

enum RelocalizationState: String, Codable {
    case idle
    case searching
    case loading
    case relocalizing
    case relocalized
    case failed
}

class RelocalizationEngine: ObservableObject {
    @Published var state: RelocalizationState = .idle
    @Published var currentSector: MapSector?
    @Published var confidence: Double = 0
    @Published var statusMessage: String = "Idle"

    private var mapManager: MapManager
    private var timeoutTimer: Timer?
    var timeoutSeconds: Double = 30

    init(mapManager: MapManager) {
        self.mapManager = mapManager
    }

    // MARK: - Public API

    func startRelocalization(arkitManager: ARKitManager, currentLocation: CLLocation) {
        state = .searching
        statusMessage = "Searching for nearby map..."

        guard let (sector, mapData) = mapManager.loadWorldMap(forLocation: currentLocation.coordinate) else {
            state = .failed
            statusMessage = "No map found for this location"
            return
        }

        currentSector = sector
        state = .loading
        statusMessage = "Loading map: \(sector.sectorId)..."

        guard let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: mapData) else {
            state = .failed
            statusMessage = "Failed to load map data"
            return
        }

        state = .relocalizing
        statusMessage = "Relocalizing..."
        arkitManager.start(with: worldMap)

        startTimeoutTimer()
    }

    func handleTrackingStateChange(_ camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            state = .relocalized
            confidence = 1.0
            statusMessage = "Relocalized ✓"
            cancelTimeout()
        case .limited(let reason):
            switch reason {
            case .relocalizing:
                state = .relocalizing
                statusMessage = "Matching features..."
            case .insufficientFeatures:
                statusMessage = "Low feature quality..."
            case .excessiveMotion:
                statusMessage = "Move slower..."
            case .initializing:
                statusMessage = "Initializing..."
            @unknown default:
                break
            }
        case .notAvailable:
            state = .failed
            statusMessage = "Tracking unavailable"
        }
    }

    func cancelRelocalization() {
        cancelTimeout()
        state = .idle
        currentSector = nil
        confidence = 0
        statusMessage = "Idle"
    }

    // MARK: - Private

    private func startTimeoutTimer() {
        cancelTimeout()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .relocalizing {
                self.state = .failed
                self.statusMessage = "Relocalization timed out"
            }
        }
    }

    private func cancelTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}
