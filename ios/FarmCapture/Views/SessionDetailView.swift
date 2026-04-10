import SwiftUI
import MapKit

struct SessionDetailView: View {
    let sessionURL: URL
    @State private var snapshots: [SensorSnapshot] = []
    @State private var selectedFrameIndex: Int?

    var body: some View {
        List {
            statsSection
            if !gpsCoordinates.isEmpty {
                mapSection
            }
            frameListSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadMetadata() }
        .fullScreenCover(item: selectedFrameBinding) { selection in
            FrameDetailView(
                snapshots: snapshots,
                currentIndex: selection.index,
                sessionURL: sessionURL
            )
        }
    }

    // MARK: - Stats

    private var depthFrameCount: Int {
        snapshots.filter { $0.hasDepth }.count
    }

    private var statsSection: some View {
        Section("Session Info") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                statCard(icon: "photo.stack", title: "Frames", value: "\(snapshots.count)")
                statCard(icon: "figure.walk", title: "Distance", value: String(format: "%.0f m", totalDistance))
                statCard(icon: "timer", title: "Duration", value: formattedDuration)
                statCard(icon: "location.fill", title: "Avg Accuracy", value: avgAccuracy)

                if depthFrameCount > 0 {
                    statCard(
                        icon: "cube.transparent",
                        title: "Depth Frames",
                        value: "\(depthFrameCount)/\(snapshots.count)"
                    )
                }
            }
        }
    }

    private func statCard(icon: String, title: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }

    // MARK: - Map

    private var mapSection: some View {
        Section("GPS Trail") {
            GPSTrailMap(coordinates: gpsCoordinates)
                .frame(height: 200)
                .cornerRadius(12)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
    }

    // MARK: - Frame List

    private var frameListSection: some View {
        Section("Frames (\(snapshots.count))") {
            ForEach(Array(snapshots.enumerated()), id: \.offset) { index, snapshot in
                FrameListRow(
                    sessionURL: sessionURL,
                    snapshot: snapshot,
                    sessionStartTime: snapshots.first?.timestamp ?? 0
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedFrameIndex = index
                }
            }
        }
    }

    // MARK: - Data

    private var sessionTitle: String {
        let name = sessionURL.lastPathComponent
        if let date = parseSessionDate(name) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return name
    }

    private var gpsCoordinates: [CLLocationCoordinate2D] {
        snapshots.compactMap { snap in
            guard let lat = snap.latitude, let lon = snap.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private var totalDistance: Double {
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

    private var formattedDuration: String {
        guard let first = snapshots.first, let last = snapshots.last else { return "—" }
        let seconds = Int(last.timestamp - first.timestamp)
        if seconds < 60 { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var avgAccuracy: String {
        let accuracies = snapshots.compactMap { $0.gpsAccuracy }
        guard !accuracies.isEmpty else { return "—" }
        let avg = accuracies.reduce(0, +) / Double(accuracies.count)
        return String(format: "±%.1f m", avg)
    }

    private func loadMetadata() {
        let metadataURL = sessionURL.appendingPathComponent("session_metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([SensorSnapshot].self, from: data) else {
            return
        }
        snapshots = decoded
    }

    private func parseSessionDate(_ folderName: String) -> Date? {
        let stripped = folderName.replacingOccurrences(of: "session_", with: "")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.date(from: stripped)
    }

    private var selectedFrameBinding: Binding<FrameSelection?> {
        Binding<FrameSelection?>(
            get: {
                guard let idx = selectedFrameIndex else { return nil }
                return FrameSelection(index: idx)
            },
            set: { newValue in
                selectedFrameIndex = newValue?.index
            }
        )
    }
}

struct FrameSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - Frame List Row

struct FrameListRow: View {
    let sessionURL: URL
    let snapshot: SensorSnapshot
    let sessionStartTime: TimeInterval

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            frameInfo
            Spacer()
            trailingIcons
        }
        .padding(.vertical, 4)
        .onAppear { loadThumbnail() }
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        .frame(width: 60, height: 60)
        .cornerRadius(8)
        .clipped()
    }

    private var frameInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Frame \(snapshot.frameId)")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                triggerBadge
            }

            Text(formattedTimestamp)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let lat = snapshot.latitude, let lon = snapshot.longitude {
                Text(String(format: "%.5f, %.5f", lat, lon))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var triggerBadge: some View {
        Text(snapshot.trigger)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(triggerColor.opacity(0.15))
            .foregroundStyle(triggerColor)
            .cornerRadius(4)
    }

    private var triggerColor: Color {
        switch snapshot.trigger {
        case "time": return .blue
        case "position": return .green
        case "heading": return .orange
        case "manual": return .purple
        default: return .gray
        }
    }

    private var trailingIcons: some View {
        HStack(spacing: 8) {
            if snapshot.hasDepth {
                Image(systemName: "cube.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var formattedTimestamp: String {
        let offset = snapshot.timestamp - sessionStartTime
        let seconds = Int(offset)
        if seconds < 60 {
            return String(format: "+%ds", seconds)
        }
        return String(format: "+%d:%02d", seconds / 60, seconds % 60)
    }

    private func loadThumbnail() {
        guard let imagePath = snapshot.imagePath else { return }
        let imageURL = sessionURL.appendingPathComponent(imagePath)

        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return }

            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 120,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }

            let uiImage = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                self.thumbnail = uiImage
            }
        }
    }
}

// MARK: - GPS Trail Map

struct GPSTrailMap: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        guard coordinates.count >= 2 else { return }

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        mapView.addOverlay(polyline)

        if let first = coordinates.first {
            let startPin = MKPointAnnotation()
            startPin.coordinate = first
            startPin.title = "Start"
            mapView.addAnnotation(startPin)
        }

        if let last = coordinates.last {
            let endPin = MKPointAnnotation()
            endPin.coordinate = last
            endPin.title = "End"
            mapView.addAnnotation(endPin)
        }

        let rect = polyline.boundingMapRect
        let insets = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mapView.setVisibleMapRect(rect, edgePadding: insets, animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(sessionURL: URL(fileURLWithPath: "/tmp"))
    }
}
