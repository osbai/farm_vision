import SwiftUI
import CoreLocation

struct SessionInfo: Identifiable {
    let id = UUID()
    let folderName: String
    let folderURL: URL
    let frameCount: Int
    let date: Date?
    let distance: Double
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
            Text(formattedDate(session.date))
                .font(.headline)

            HStack(spacing: 16) {
                Label("\(session.frameCount) frames", systemImage: "photo.stack")
                Label(String(format: "%.0f m", session.distance), systemImage: "figure.walk")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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

            return SessionInfo(
                folderName: folderName,
                folderURL: folderURL,
                frameCount: jpgFiles.count,
                date: date,
                distance: distance
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
