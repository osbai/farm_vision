import SwiftUI
import CoreLocation

struct SessionSizeBreakdown {
    var images: Int64 = 0
    var depth: Int64 = 0
    var confidence: Int64 = 0
    var pointCloud: Int64 = 0
    var worldMap: Int64 = 0
    var metadata: Int64 = 0

    var total: Int64 {
        images + depth + confidence + pointCloud + worldMap + metadata
    }
}

struct SessionInfo: Identifiable {
    let id = UUID()
    let folderName: String
    let folderURL: URL
    let frameCount: Int
    let date: Date?
    let distance: Double
    let sizeBreakdown: SessionSizeBreakdown
}

struct SessionListView: View {
    @State private var sessions: [SessionInfo] = []

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .onAppear { loadSessions() }
            .refreshable { loadSessions() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Sessions Yet")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Captured sessions will appear here.\nSwitch to the Capture tab to start recording.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var sessionList: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink(destination: SessionDetailView(sessionURL: session.folderURL)) {
                    sessionRow(session)
                }
            }
            .onDelete(perform: deleteSessions)
        }
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(formattedDate(session.date))
                    .font(.headline)
                Spacer()
                Text(formattedSize(session.sizeBreakdown.total))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 16) {
                Label("\(session.frameCount) frames", systemImage: "photo.stack")
                Label(String(format: "%.0f m", session.distance), systemImage: "figure.walk")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            sizeBreakdownRow(session.sizeBreakdown)
        }
        .padding(.vertical, 4)
    }

    private func sizeBreakdownRow(_ breakdown: SessionSizeBreakdown) -> some View {
        let items: [(String, Int64, Color)] = [
            ("IMG", breakdown.images, .green),
            ("Depth", breakdown.depth, .blue),
            ("Conf", breakdown.confidence, .cyan),
            ("Map", breakdown.worldMap, .orange),
            ("PLY", breakdown.pointCloud, .purple),
        ].filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }

        return HStack(spacing: 8) {
            ForEach(items.prefix(4), id: \.0) { label, bytes, color in
                HStack(spacing: 2) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text("\(label) \(formattedSize(bytes))")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Unknown Date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func loadSessions() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            sessions = []
            return
        }

        let sessionFolders = contents.filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue && url.lastPathComponent.hasPrefix("session_")
        }

        sessions = sessionFolders.compactMap { folderURL in
            let folderName = folderURL.lastPathComponent

            let jpgFiles = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension.lowercased() == "jpg"
            } ?? []

            let date = parseSessionDate(folderName)

            var distance: Double = 0
            let metadataURL = folderURL.appendingPathComponent("session_metadata.json")
            if let data = try? Data(contentsOf: metadataURL),
               let snapshots = try? JSONDecoder().decode([SensorSnapshot].self, from: data) {
                distance = computeDistance(from: snapshots)
            }

            let sizeBreakdown = computeSizeBreakdown(folderURL)

            return SessionInfo(
                folderName: folderName,
                folderURL: folderURL,
                frameCount: jpgFiles.count,
                date: date,
                distance: distance,
                sizeBreakdown: sizeBreakdown
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private func parseSessionDate(_ folderName: String) -> Date? {
        let stripped = folderName.replacingOccurrences(of: "session_", with: "")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.date(from: stripped)
    }

    private func computeDistance(from snapshots: [SensorSnapshot]) -> Double {
        var total: Double = 0
        var prevLat: Double?
        var prevLon: Double?
        for snap in snapshots {
            guard let lat = snap.latitude, let lon = snap.longitude else { continue }
            if let pLat = prevLat, let pLon = prevLon {
                let a = CLLocation(latitude: pLat, longitude: pLon)
                let b = CLLocation(latitude: lat, longitude: lon)
                total += a.distance(from: b)
            }
            prevLat = lat
            prevLon = lon
        }
        return total
    }

    private func computeSizeBreakdown(_ folderURL: URL) -> SessionSizeBreakdown {
        var breakdown = SessionSizeBreakdown()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return breakdown }

        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let name = file.lastPathComponent
            let ext = file.pathExtension.lowercased()

            if ext == "jpg" || ext == "jpeg" {
                breakdown.images += size
            } else if name.hasPrefix("depth_") && ext == "png" {
                breakdown.depth += size
            } else if name.hasPrefix("confidence_") && ext == "png" {
                breakdown.confidence += size
            } else if name == "pointcloud.ply" {
                breakdown.pointCloud += size
            } else if name == "world_map.arworldmap" {
                breakdown.worldMap += size
            } else if name == "session_metadata.json" {
                breakdown.metadata += size
            } else {
                breakdown.metadata += size
            }
        }
        return breakdown
    }

    private func formattedSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            try? FileManager.default.removeItem(at: session.folderURL)
        }
        sessions.remove(atOffsets: offsets)
    }
}

#Preview {
    SessionListView()
}
