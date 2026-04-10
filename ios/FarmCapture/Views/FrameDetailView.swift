import SwiftUI
import MapKit

// MARK: - FrameDetailView

struct FrameDetailView: View {
    let snapshots: [SensorSnapshot]
    @State var currentIndex: Int
    let sessionURL: URL

    @State private var showOverlay = false
    @State private var showDepth = false
    @State private var imageExpanded = false
    @Environment(\.dismiss) private var dismiss

    private var currentSnapshot: SensorSnapshot {
        snapshots[currentIndex]
    }

    private var gpsCoordinates: [CLLocationCoordinate2D] {
        snapshots.compactMap { snapshot in
            guard let lat = snapshot.latitude, let lon = snapshot.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        guard let lat = currentSnapshot.latitude, let lon = currentSnapshot.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        ZStack {
            // Full-screen map background
            FrameTrailMapView(
                coordinates: gpsCoordinates,
                currentCoordinate: currentCoordinate
            )
            .ignoresSafeArea()

            // Top bar
            VStack(spacing: 0) {
                topBar
                Spacer()
            }

            // Bottom image card + controls
            VStack(spacing: 0) {
                Spacer()
                imageCard
            }
        }
        .statusBarHidden(true)
        .onChange(of: currentIndex) { _, _ in
            if showDepth && !currentSnapshot.hasDepth {
                showDepth = false
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }

                Spacer()

                Text("Frame \(currentIndex + 1) of \(snapshots.count)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5))
                    .cornerRadius(12)

                Spacer()

                if currentSnapshot.hasDepth {
                    depthToggle
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.5), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            .allowsHitTesting(false),
            alignment: .top
        )
    }

    private var depthToggle: some View {
        Button(action: { showDepth.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: showDepth ? "cube.fill" : "cube")
                Text(showDepth ? "RGB" : "Depth")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(showDepth ? Color.blue : Color.black.opacity(0.5))
            .cornerRadius(16)
        }
    }

    // MARK: - Image Card

    private var imageCard: some View {
        VStack(spacing: 0) {
            // Navigation row
            navigationControls

            // Image panel
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)

                FrameImageView(
                    sessionURL: sessionURL,
                    snapshot: currentSnapshot,
                    showDepth: showDepth
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(8)
                .onTapGesture {
                    withAnimation(.spring(response: 0.3)) {
                        imageExpanded.toggle()
                    }
                }

                // Sensor overlay on the card
                if showOverlay {
                    VStack {
                        Spacer()
                        sensorOverlay
                    }
                    .padding(8)
                }
            }
            .frame(height: imageExpanded
                ? UIScreen.main.bounds.height * 0.65
                : UIScreen.main.bounds.height * 0.38)
            .animation(.spring(response: 0.3), value: imageExpanded)

            // Info toggle strip
            infoToggleStrip
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var navigationControls: some View {
        HStack {
            Button(action: {
                if currentIndex > 0 { currentIndex -= 1 }
            }) {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .foregroundStyle(currentIndex > 0 ? .white : .white.opacity(0.3))
                    .shadow(radius: 3)
            }
            .disabled(currentIndex == 0)

            Spacer()

            Text(currentSnapshot.trigger.capitalized)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .cornerRadius(8)

            Spacer()

            Button(action: {
                if currentIndex < snapshots.count - 1 { currentIndex += 1 }
            }) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(currentIndex < snapshots.count - 1 ? .white : .white.opacity(0.3))
                    .shadow(radius: 3)
            }
            .disabled(currentIndex >= snapshots.count - 1)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var infoToggleStrip: some View {
        Button(action: { showOverlay.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: showOverlay ? "info.circle.fill" : "info.circle")
                Text("Sensor Data")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Sensor Data Overlay

    private var sensorOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            overlayRow("Frame", value: "#\(currentSnapshot.frameId)")
            overlayRow("Trigger", value: currentSnapshot.trigger)

            if let lat = currentSnapshot.latitude, let lon = currentSnapshot.longitude {
                overlayRow("GPS", value: String(format: "%.6f, %.6f", lat, lon))
            }

            if let alt = currentSnapshot.altitude {
                overlayRow("Altitude", value: String(format: "%.1f m", alt))
            }

            if let acc = currentSnapshot.gpsAccuracy {
                overlayRow("GPS Accuracy", value: String(format: "±%.1f m", acc))
            }

            if let heading = currentSnapshot.heading {
                overlayRow("Heading", value: String(format: "%.1f°", heading))
            }

            if let pitch = currentSnapshot.pitch, let roll = currentSnapshot.roll, let yaw = currentSnapshot.yaw {
                overlayRow("Orientation", value: String(format: "P:%.1f° R:%.1f° Y:%.1f°", degrees(pitch), degrees(roll), degrees(yaw)))
            }

            if let speed = currentSnapshot.speed, speed >= 0 {
                overlayRow("Speed", value: String(format: "%.1f m/s", speed))
            }

            if let pressure = currentSnapshot.pressure {
                overlayRow("Pressure", value: String(format: "%.1f hPa", pressure))
            }

            if currentSnapshot.hasDepth {
                Divider().background(.white.opacity(0.3))
                overlayRow("Depth", value: "Available ✓")
            }
        }
        .padding(10)
        .background(.ultraThinMaterial.opacity(0.95))
        .cornerRadius(10)
        .allowsHitTesting(false)
    }

    private func overlayRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
    }

    private func degrees(_ radians: Double) -> Double {
        radians * 180.0 / .pi
    }
}

// MARK: - Frame Image View

struct FrameImageView: View {
    let sessionURL: URL
    let snapshot: SensorSnapshot
    let showDepth: Bool

    @State private var image: UIImage?
    @State private var depthImage: UIImage?
    @State private var depthStats: DepthStats?

    var body: some View {
        ZStack {
            Group {
                if showDepth, let depthImage {
                    Image(uiImage: depthImage)
                        .resizable()
                        .scaledToFit()
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }

            if showDepth, let stats = depthStats {
                VStack {
                    depthStatsOverlay(stats)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .onAppear { loadImage() }
        .onChange(of: showDepth) { _, newValue in
            if newValue && depthImage == nil {
                loadDepthImage()
            }
        }
    }

    private func depthStatsOverlay(_ stats: DepthStats) -> some View {
        HStack(spacing: 16) {
            depthStatItem("Min", value: String(format: "%.2f m", stats.minDepth))
            depthStatItem("Max", value: String(format: "%.2f m", stats.maxDepth))
            depthStatItem("Mean", value: String(format: "%.2f m", stats.meanDepth))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6))
        .cornerRadius(10)
    }

    private func depthStatItem(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
        }
    }

    private func loadImage() {
        guard let imagePath = snapshot.imagePath else { return }
        let imageURL = sessionURL.appendingPathComponent(imagePath)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: imageURL),
                  let loaded = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.image = loaded
            }
        }

        if snapshot.hasDepth {
            loadDepthImage()
        }
    }

    private func loadDepthImage() {
        guard let depthPath = snapshot.depthPath else { return }
        let depthURL = sessionURL.appendingPathComponent(depthPath)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let result = DepthMapRenderer.render(depthURL: depthURL) else { return }
            DispatchQueue.main.async {
                self.depthImage = result.image
                self.depthStats = result.stats
            }
        }
    }
}

// MARK: - Frame Trail Map (UIViewRepresentable)

struct FrameTrailMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let currentCoordinate: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.isRotateEnabled = true
        mapView.delegate = context.coordinator
        mapView.mapType = .hybrid
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        guard !coordinates.isEmpty else { return }

        // Draw GPS trail polyline
        if coordinates.count >= 2 {
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline)
        }

        // Add start/end markers
        if let first = coordinates.first {
            let startPin = MKPointAnnotation()
            startPin.coordinate = first
            startPin.title = "Start"
            mapView.addAnnotation(startPin)
        }

        if coordinates.count > 1, let last = coordinates.last {
            let endPin = MKPointAnnotation()
            endPin.coordinate = last
            endPin.title = "End"
            mapView.addAnnotation(endPin)
        }

        // Highlighted current-frame pin
        if let current = currentCoordinate {
            let currentPin = CurrentFrameAnnotation()
            currentPin.coordinate = current
            currentPin.title = "Current Frame"
            mapView.addAnnotation(currentPin)

            // Center on the current frame
            let region = MKCoordinateRegion(
                center: current,
                latitudinalMeters: 200,
                longitudinalMeters: 200
            )
            mapView.setRegion(region, animated: true)
        } else if !coordinates.isEmpty {
            let rect = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
            let insets = UIEdgeInsets(top: 60, left: 40, bottom: UIScreen.main.bounds.height * 0.45, right: 40)
            mapView.setVisibleMapRect(rect, edgePadding: insets, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemCyan
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is CurrentFrameAnnotation {
                let identifier = "CurrentFrame"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                if view == nil {
                    view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                }
                view?.annotation = annotation
                view?.markerTintColor = .systemOrange
                view?.glyphImage = UIImage(systemName: "camera.fill")
                view?.displayPriority = .required
                view?.animatesWhenAdded = true
                return view
            }
            return nil
        }
    }
}

// Custom annotation class to distinguish the current frame pin
class CurrentFrameAnnotation: MKPointAnnotation {}

// MARK: - Preview

#Preview {
    FrameDetailView(
        snapshots: [],
        currentIndex: 0,
        sessionURL: URL(fileURLWithPath: "/tmp")
    )
}
