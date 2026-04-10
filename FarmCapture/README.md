# FarmCapture

iOS app for capturing synchronized sensor data (GPS, compass, IMU, barometer, camera) during farm field sweeps. Designed for 3D reconstruction and precision agriculture workflows.

## Requirements

- Xcode 15+
- iOS 16+ deployment target
- Physical iOS device (camera and sensors are not available in Simulator)

## Deploy to iPhone — Step by Step

### Prerequisites

- Mac with Xcode 15+ installed
- iPhone 12 or newer, connected via USB cable
- Free Apple Developer account (your Apple ID)

### Steps

1. Open Xcode
2. **File → New → Project → iOS → App**
   - Product Name: `FarmCapture`
   - Team: Select your Apple ID
   - Organization Identifier: `com.farmvision`
   - Interface: SwiftUI
   - Language: Swift
   - Uncheck "Include Tests"
3. Save the project somewhere (e.g., Desktop)
4. In the project navigator, delete the auto-generated `ContentView.swift` (Move to Trash)
5. Right-click on the `FarmCapture` folder in the navigator → **Add Files to "FarmCapture"**
   - Navigate to `/Users/sbaio/farm_vision/FarmCapture/FarmCapture/`
   - Select ALL files and folders (Sensors/, Models/, Utils/, ContentView.swift, FarmCaptureApp.swift, Info.plist)
   - ✅ Copy items if needed
   - ✅ Create groups
   - Click Add
6. If Xcode shows duplicate `FarmCaptureApp.swift`, delete the auto-generated one
7. Select your iPhone from the device dropdown (top of Xcode, next to the play button)
8. Click ▶️ (or ⌘R) to build and run
9. On first run, iPhone will say "Untrusted Developer":
   - Go to **Settings → General → VPN & Device Management**
   - Tap your developer profile → Trust
   - Run again from Xcode

> **Note:** `CoreLocation`, `CoreMotion`, and `AVFoundation` are auto-linked via Swift imports — no manual framework linking is required.

### Getting data off the iPhone

- Open Finder on Mac → Click your iPhone in sidebar → Files tab
- Find FarmCapture → Drag session folders to your Mac

### Simulating GPS location for testing

A GPX file (`FarmLocation.gpx`) is included at the project root. It contains a 28-point walking route around the farm boundary near Meknes. To use it in Xcode:

1. In Xcode, go to **Debug → Simulate Location → Add GPX File to Project...**
2. Select `FarmLocation.gpx`
3. When running on a device or simulator, use **Debug → Simulate Location → Meknes Farm Walk** to replay the GPS track

This is useful for testing the app's GPS tracking and adaptive capture logic without being physically at the farm.

## Project Structure

```text
FarmCapture/
├── FarmCaptureApp.swift              # SwiftUI app entry point
├── ContentView.swift                 # Camera preview + sweep controls
├── Sensors/
│   ├── SensorManager.swift           # Orchestrates all sensors, produces snapshots
│   ├── LocationManager.swift         # CoreLocation: GPS + compass heading
│   ├── MotionManager.swift           # CoreMotion: IMU attitude + barometer
│   └── CameraManager.swift           # AVFoundation: camera frame capture
├── Models/
│   ├── SensorSnapshot.swift          # Codable data model for sensor readings
│   └── CaptureSession.swift          # Manages session directory, frame saving, metadata
├── Utils/
│   └── AdaptiveCapturePolicy.swift   # Adaptive keyframe capture logic
└── Info.plist                        # Privacy permission descriptions + file sharing
```

## Usage

1. Launch the app on a physical device.
2. Grant camera, location, and motion permissions when prompted.
3. The camera preview fills the screen with a GPS accuracy indicator at the top.
4. Tap the **red button** to start a sweep. Walk through the field while the app automatically captures keyframes.
5. Tap the **red stop button** to end the sweep. Data is saved to the app's Documents directory.
6. Use the **blue camera button** for manual single-shot captures at any time.

## Output Format

Each sweep session creates a timestamped directory (e.g., `session_2026-04-09_103000/`) containing:

- `frame_00000.jpg`, `frame_00001.jpg`, ... — JPEG images (720p, quality 0.7)
- `session_metadata.json` — Array of `SensorSnapshot` objects with all sensor readings

## Adaptive Capture Policy

- **Default**: 5 fps (one frame every 200ms)
- **Boost**: Captures sooner when position moves >0.15m, heading changes >5°, or pitch changes >10°
- **Idle**: Drops to 1 fps when standing still (position <0.05m, heading <2°)
- **Max cap**: Never exceeds 10 fps

## Accessing Data

Connect the device to a Mac, open Finder, select the device, and navigate to **Files → FarmCapture** to download session directories. Alternatively, use Xcode's **Devices and Simulators** window to download the app container.
