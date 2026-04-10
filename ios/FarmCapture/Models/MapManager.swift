import Foundation
import CoreLocation
import MapKit
import Combine

// MARK: - Bounding Box

struct BoundingBox: Codable {
    let minLat: Double
    let minLon: Double
    let maxLat: Double
    let maxLon: Double

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLat && coordinate.latitude <= maxLat &&
        coordinate.longitude >= minLon && coordinate.longitude <= maxLon
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2.0,
            longitude: (minLon + maxLon) / 2.0
        )
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return centerLocation.distance(from: targetLocation)
    }
}

// MARK: - Map Sector Model

struct MapSector: Codable, Identifiable {
    let sectorId: String
    let boundingBox: BoundingBox
    let captureDate: Date
    var mapFilePath: String
    var pointCloudPath: String?
    var frameCount: Int
    var version: Int

    var id: String { sectorId }

    var age: TimeInterval {
        Date().timeIntervalSince(captureDate)
    }

    var isStale: Bool {
        age > 30 * 86400
    }
}

// MARK: - Sector Metadata (per-sector JSON)

struct SectorMetadata: Codable {
    let sectorId: String
    let captureDate: Date
    let frameCount: Int
    let boundingBox: BoundingBox
    let version: Int
    let deviceModel: String
    let appVersion: String

    init(sector: MapSector, deviceModel: String = "", appVersion: String = "1.0") {
        self.sectorId = sector.sectorId
        self.captureDate = sector.captureDate
        self.frameCount = sector.frameCount
        self.boundingBox = sector.boundingBox
        self.version = sector.version
        self.deviceModel = deviceModel
        self.appVersion = appVersion
    }
}

// MARK: - Map Manager

class MapManager: ObservableObject {
    @Published var sectors: [MapSector] = []
    @Published var currentSector: MapSector?

    private let mapsDirectory: URL
    private let indexFile: URL
    private let fileManager = FileManager.default

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mapsDirectory = docs.appendingPathComponent("maps")
        indexFile = mapsDirectory.appendingPathComponent("sector_index.json")
        createDirectoryIfNeeded()
        loadSectorIndex()
    }

    // MARK: - Save World Map

    func saveWorldMap(
        _ mapData: Data,
        center: CLLocationCoordinate2D,
        bounds: BoundingBox,
        frameCount: Int
    ) -> MapSector? {
        let sectorId = nextSectorId()
        let sectorDir = mapsDirectory.appendingPathComponent(sectorId)

        do {
            try fileManager.createDirectory(at: sectorDir, withIntermediateDirectories: true)
        } catch {
            print("[MapManager] Failed to create sector directory: \(error)")
            return nil
        }

        let mapFile = sectorDir.appendingPathComponent("world_map.arworldmap")
        do {
            try mapData.write(to: mapFile)
        } catch {
            print("[MapManager] Failed to write world map: \(error)")
            return nil
        }

        let sector = MapSector(
            sectorId: sectorId,
            boundingBox: bounds,
            captureDate: Date(),
            mapFilePath: mapFile.lastPathComponent,
            pointCloudPath: nil,
            frameCount: frameCount,
            version: 1
        )

        let metadata = SectorMetadata(sector: sector)
        let metadataFile = sectorDir.appendingPathComponent("metadata.json")
        do {
            let metadataData = try encoder.encode(metadata)
            try metadataData.write(to: metadataFile)
        } catch {
            print("[MapManager] Failed to write sector metadata: \(error)")
        }

        sectors.append(sector)
        currentSector = sector
        saveSectorIndex()

        print("[MapManager] Saved sector \(sectorId) with \(frameCount) frames")
        return sector
    }

    // MARK: - Load World Map

    func loadWorldMap(forLocation coordinate: CLLocationCoordinate2D) -> (MapSector, Data)? {
        guard let sector = findNearestSector(to: coordinate) else {
            print("[MapManager] No sector found near \(coordinate.latitude), \(coordinate.longitude)")
            return nil
        }

        let sectorDir = mapsDirectory.appendingPathComponent(sector.sectorId)
        let mapFile = sectorDir.appendingPathComponent(sector.mapFilePath)

        guard fileManager.fileExists(atPath: mapFile.path) else {
            print("[MapManager] World map file missing for sector \(sector.sectorId)")
            return nil
        }

        do {
            let data = try Data(contentsOf: mapFile)
            print("[MapManager] Loaded world map for sector \(sector.sectorId) (\(data.count) bytes)")
            return (sector, data)
        } catch {
            print("[MapManager] Failed to read world map: \(error)")
            return nil
        }
    }

    // MARK: - Find Sector

    func findSector(at coordinate: CLLocationCoordinate2D) -> MapSector? {
        sectors.first { $0.boundingBox.contains(coordinate) }
    }

    func findNearestSector(to coordinate: CLLocationCoordinate2D, maxDistance: CLLocationDistance = 500) -> MapSector? {
        let candidates = sectors
            .map { (sector: $0, distance: $0.boundingBox.distance(to: coordinate)) }
            .filter { $0.distance <= maxDistance }
            .sorted { $0.distance < $1.distance }

        return candidates.first?.sector
    }

    // MARK: - Delete Sector

    func deleteSector(_ sectorId: String) {
        let sectorDir = mapsDirectory.appendingPathComponent(sectorId)

        do {
            if fileManager.fileExists(atPath: sectorDir.path) {
                try fileManager.removeItem(at: sectorDir)
            }
        } catch {
            print("[MapManager] Failed to delete sector directory: \(error)")
        }

        sectors.removeAll { $0.sectorId == sectorId }
        if currentSector?.sectorId == sectorId {
            currentSector = nil
        }
        saveSectorIndex()

        print("[MapManager] Deleted sector \(sectorId)")
    }

    // MARK: - Stale Sector Cleanup

    func cleanupStaleSectors() {
        let stale = sectors.filter { $0.isStale }
        for sector in stale {
            deleteSector(sector.sectorId)
        }
        if !stale.isEmpty {
            print("[MapManager] Cleaned up \(stale.count) stale sectors")
        }
    }

    // MARK: - Public Accessors

    func pointCloudURL(for sector: MapSector) -> URL? {
        guard sector.pointCloudPath != nil else { return nil }
        return mapsDirectory
            .appendingPathComponent(sector.sectorId)
            .appendingPathComponent("pointcloud.ply")
    }

    // MARK: - Point Cloud Association

    func attachPointCloud(data: Data, toSector sectorId: String) -> Bool {
        guard let index = sectors.firstIndex(where: { $0.sectorId == sectorId }) else {
            return false
        }

        let sectorDir = mapsDirectory.appendingPathComponent(sectorId)
        let plyFile = sectorDir.appendingPathComponent("pointcloud.ply")

        do {
            try data.write(to: plyFile)
            sectors[index].pointCloudPath = plyFile.lastPathComponent
            saveSectorIndex()
            print("[MapManager] Attached point cloud to sector \(sectorId)")
            return true
        } catch {
            print("[MapManager] Failed to write point cloud: \(error)")
            return false
        }
    }

    // MARK: - Persistence

    private func saveSectorIndex() {
        do {
            let data = try encoder.encode(sectors)
            try data.write(to: indexFile)
        } catch {
            print("[MapManager] Failed to save sector index: \(error)")
        }
    }

    private func loadSectorIndex() {
        guard fileManager.fileExists(atPath: indexFile.path) else {
            sectors = []
            return
        }

        do {
            let data = try Data(contentsOf: indexFile)
            sectors = try decoder.decode([MapSector].self, from: data)
            print("[MapManager] Loaded \(sectors.count) sectors from index")
        } catch {
            print("[MapManager] Failed to load sector index: \(error)")
            sectors = []
        }
    }

    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: mapsDirectory.path) {
            do {
                try fileManager.createDirectory(at: mapsDirectory, withIntermediateDirectories: true)
            } catch {
                print("[MapManager] Failed to create maps directory: \(error)")
            }
        }
    }

    private func nextSectorId() -> String {
        let existing = sectors.compactMap { sector -> Int? in
            let parts = sector.sectorId.split(separator: "_")
            guard parts.count == 2, let num = Int(parts[1]) else { return nil }
            return num
        }
        let next = (existing.max() ?? 0) + 1
        return String(format: "sector_%03d", next)
    }
}
