import SwiftUI
import ARKit

struct ARPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = session
        arView.automaticallyUpdatesLighting = true
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem {
                    Label("Capture", systemImage: "camera.fill")
                }

            SessionListView()
                .tabItem {
                    Label("Sessions", systemImage: "folder.fill")
                }

            Text("Maps coming soon")
                .tabItem {
                    Label("Maps", systemImage: "map.fill")
                }
        }
    }
}

struct CaptureView: View {
    @StateObject private var sensorManager = SensorManager()

    var body: some View {
        ZStack {
            ARPreviewView(session: sensorManager.arkitManager.arSession)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .onAppear {
            sensorManager.setup()
            sensorManager.startSensors()
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            gpsIndicator
            trackingIndicator
            lidarIndicator
            mappingIndicator
            Spacer()
            if sensorManager.isSweeping {
                sweepStats
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var gpsIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(gpsColor)
                .frame(width: 10, height: 10)
            Text(gpsText)
                .font(.caption)
                .foregroundColor(.white)
        }
    }

    private var trackingIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(trackingColor)
                .frame(width: 10, height: 10)
            Text(trackingText)
                .font(.caption)
                .foregroundColor(.white)
        }
    }

    private var trackingColor: Color {
        switch sensorManager.trackingState {
        case "normal":
            return .green
        case let s where s.hasPrefix("limited"):
            return .yellow
        default:
            return .red
        }
    }

    private var trackingText: String {
        switch sensorManager.trackingState {
        case "normal":
            return "Tracking ✓"
        case let s where s.hasPrefix("limited"):
            return "Limited"
        default:
            return "No Tracking"
        }
    }

    private var lidarIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "cube.fill")
                .font(.caption2)
            Text(sensorManager.isLiDARAvailable ? "LiDAR ✓" : "No LiDAR")
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(sensorManager.isLiDARAvailable ? Color.green.opacity(0.8) : Color.gray.opacity(0.6))
        .foregroundColor(.white)
        .clipShape(Capsule())
    }

    private var mappingIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "map.fill")
                .font(.caption2)
            Text(mappingText)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(mappingColor.opacity(0.8))
        .foregroundColor(.white)
        .clipShape(Capsule())
    }

    private var mappingColor: Color {
        switch sensorManager.worldMappingStatus {
        case "mapped":
            return .green
        case "extending":
            return .blue
        case "limited":
            return .yellow
        default:
            return .gray
        }
    }

    private var mappingText: String {
        switch sensorManager.worldMappingStatus {
        case "mapped":
            return "Mapped ✓"
        case "extending":
            return "Mapping..."
        case "limited":
            return "Limited"
        default:
            return "Not Mapped"
        }
    }

    private var gpsColor: Color {
        guard let accuracy = sensorManager.locationManager.gpsAccuracy else { return .red }
        if accuracy < 5 { return .green }
        if accuracy < 15 { return .yellow }
        return .orange
    }

    private var gpsText: String {
        guard let accuracy = sensorManager.locationManager.gpsAccuracy else { return "No GPS" }
        return String(format: "GPS ±%.0fm", accuracy)
    }

    private var sweepStats: some View {
        HStack(spacing: 12) {
            Label(String(format: "%.1f fps", sensorManager.currentFPS), systemImage: "speedometer")
            Label("\(sensorManager.framesCaptured)", systemImage: "photo.stack")
            Label(formattedDuration, systemImage: "timer")
            Label(String(format: "%.0fm", sensorManager.distanceWalked), systemImage: "figure.walk")
        }
        .font(.caption)
        .foregroundColor(.white)
    }

    private var formattedDuration: String {
        let t = Int(sensorManager.sessionDuration)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var bottomControls: some View {
        HStack(spacing: 40) {
            manualCaptureButton
            sweepButton
            Spacer().frame(width: 60)
        }
        .padding(.bottom, 30)
    }

    private var sweepButton: some View {
        Button(action: {
            if sensorManager.isSweeping {
                sensorManager.stopSweep()
            } else {
                sensorManager.startSweep()
            }
        }) {
            ZStack {
                Circle()
                    .fill(sensorManager.isSweeping ? Color.red.opacity(0.8) : Color.red)
                    .frame(width: 72, height: 72)
                if sensorManager.isSweeping {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 28, height: 28)
                }
            }
        }
    }

    private var manualCaptureButton: some View {
        Button(action: {
            if let data = sensorManager.latestImageData {
                sensorManager.captureManualFrame(imageData: data)
            }
        }) {
            Circle()
                .strokeBorder(Color.blue, lineWidth: 3)
                .background(Circle().fill(Color.blue.opacity(0.3)))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "camera.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 20))
                )
        }
    }
}

#Preview {
    ContentView()
}
