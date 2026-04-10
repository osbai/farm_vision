import SwiftUI
import MapKit

// MARK: - BoundingBox + MapKit

extension BoundingBox {
    var corners: [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: maxLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
        ]
    }
}

// MARK: - MapSectorsView

struct MapSectorsView: View {
    @StateObject private var mapManager = MapManager()

    var body: some View {
        NavigationStack {
            ZStack {
                // Satellite map showing all sectors as colored rectangles
                Map {
                    ForEach(mapManager.sectors) { sector in
                        MapPolygon(coordinates: sector.boundingBox.corners)
                            .foregroundStyle(sectorColor(sector).opacity(0.3))
                            .stroke(sectorColor(sector), lineWidth: 2)
                    }
                }
                .mapStyle(.imagery)

                if mapManager.sectors.isEmpty {
                    emptyState
                }
            }
            .navigationTitle("Mapped Sectors")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    sectorList
                }
            }
        }
    }

    // Color by freshness
    private func sectorColor(_ sector: MapSector) -> Color {
        let days = sector.age / 86400
        if days < 7 { return .green }
        if days < 30 { return .yellow }
        return .red
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Mapped Sectors")
                .font(.title3)
                .fontWeight(.medium)
            Text("Start a capture sweep to map an area")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }

    private var sectorList: some View {
        Menu {
            ForEach(mapManager.sectors) { sector in
                Button {
                    // Focus on sector
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(sector.sectorId)
                            Text("v\(sector.version) • \(sector.frameCount) frames")
                                .font(.caption)
                        }
                    } icon: {
                        Image(systemName: "map.fill")
                            .foregroundStyle(sectorColor(sector))
                    }
                }
            }

            if !mapManager.sectors.isEmpty {
                Divider()
                Button(role: .destructive) {
                    mapManager.cleanupStaleSectors()
                } label: {
                    Label("Clean Up Stale Maps", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
    }
}
