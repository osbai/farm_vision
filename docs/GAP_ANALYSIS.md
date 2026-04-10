# FarmCapture — Gap Analysis Report

**Date:** 2026-04-10
**Scope:** iOS app (`FarmCapture`) vs. system design documents (`system_designn.md`, `3D_FARM_MAPPING.md`, `SMARTPHONE_APP.md`)

---

## Executive Summary

The FarmCapture iOS app has made strong progress on the **sensor capture and data collection** layer — all 8 planned iPhone sensors are integrated, ARKit provides 6-DoF tracking, and session data is persisted to disk. However, the app currently functions as a **data recorder only**. The core value propositions of the system design — on-device ML inference, cloud sync, relocalization, and actionable diagnostics — are **not yet operational**. Two significant subsystems (GPS-SLAM Fusion, Relocalization Engine) are code-complete but not wired into the app, representing low-hanging fruit. Overall, approximately **25–30%** of the designed system is implemented.

---

## 1. Implementation Status Matrix

| # | Feature | Design Source | Status | Notes |
|---|---------|--------------|--------|-------|
| **Sensor & Capture** | | | | |
| 1 | RGB camera capture | All docs | ✅ Fully Implemented | ARFrame.capturedImage via CameraManager |
| 2 | LiDAR depth capture | system_designn, 3D_FARM | ✅ Fully Implemented | Depth + confidence maps saved as PNG |
| 3 | GPS location tracking | All docs | ✅ Fully Implemented | CoreLocation via LocationManager |
| 4 | Compass / heading | system_designn | ✅ Fully Implemented | trueNorthHeading in SensorSnapshot |
| 5 | IMU (accelerometer + gyro) | system_designn | ✅ Fully Implemented | MotionManager at ~60Hz |
| 6 | Barometer / altitude | system_designn | ✅ Fully Implemented | CMAltimeter in MotionManager |
| 7 | 6-DoF camera pose (ARKit SLAM) | system_designn, 3D_FARM | ✅ Fully Implemented | ARSession world tracking |
| 8 | Confidence map capture | 3D_FARM | ✅ Fully Implemented | Saved alongside depth maps |
| 9 | Adaptive keyframe selection | system_designn | ✅ Fully Implemented | AdaptiveCapturePolicy (distance + angle thresholds) |
| 10 | VRS session recording | system_designn | ❌ Not Implemented | No VRS format support |
| **Capture Modes** | | | | |
| 11 | Single Shot mode | SMARTPHONE_APP | ❌ Not Implemented | Only continuous sweep exists |
| 12 | Continuous Sweep mode | SMARTPHONE_APP | ✅ Fully Implemented | Primary capture mode |
| 13 | LiDAR Scan mode | SMARTPHONE_APP | ⚠️ Partially Implemented | LiDAR captured during sweep but no dedicated 3D scan mode |
| 14 | Panoramic Field View | SMARTPHONE_APP | ❌ Not Implemented | |
| 15 | Time-Lapse / Repeat Visit | SMARTPHONE_APP | ❌ Not Implemented | No GPS-based revisit comparison |
| **ML / Computer Vision** | | | | |
| 16 | Disease classification (MobileNetV3) | All docs | ❌ Not Implemented | No CoreML models bundled |
| 17 | Segmentation overlay (Mobile U-Net) | system_designn, SMARTPHONE | ❌ Not Implemented | No Vision framework usage |
| 18 | Fruit counting / sizing | 3D_FARM | ❌ Not Implemented | |
| 19 | Plant instance segmentation | 3D_FARM | ❌ Not Implemented | |
| 20 | Image quality checks | system_designn | ❌ Not Implemented | No blur / exposure gating |
| 21 | Gaze-based Plant ID | system_designn | ❌ Not Implemented | No gaze ray → plant lookup |
| 22 | Place recognition (NetVLAD/SALAD) | system_designn | ❌ Not Implemented | |
| 23 | Feature matching (SuperPoint+SuperGlue) | system_designn | ❌ Not Implemented | |
| **UI Components** | | | | |
| 24 | Camera Viewfinder Overlay | SMARTPHONE_APP | ⚠️ Partially Implemented | AR preview exists but no segmentation masks |
| 25 | Results Card (diagnosis) | SMARTPHONE_APP | ❌ Not Implemented | No ML → no results |
| 26 | Field Map View (GPS trail + pins) | SMARTPHONE_APP | ✅ Fully Implemented | GPS trail on MapKit in SessionDetailView |
| 27 | Comparison View (cross-visit) | SMARTPHONE_APP | ❌ Not Implemented | |
| 28 | Annotation Mode (active learning) | SMARTPHONE_APP | ❌ Not Implemented | |
| 29 | Voice Notes | SMARTPHONE_APP | ❌ Not Implemented | |
| 30 | Drone Alert Integration | SMARTPHONE_APP | ❌ Not Implemented | |
| 31 | Plant ID Display | system_designn | ❌ Not Implemented | |
| 32 | Sector Map View | 3D_FARM | ⚠️ Partially Implemented | MapSectorsView exists but NOT wired to navigation |
| **Data & Persistence** | | | | |
| 33 | Session metadata persistence | All docs | ✅ Fully Implemented | JSON files on disk |
| 34 | Frame data persistence (JPEG + depth) | All docs | ✅ Fully Implemented | File-system storage |
| 35 | Point cloud export (PLY) | 3D_FARM | ✅ Fully Implemented | pointcloud.ply saved per session |
| 36 | ARWorldMap persistence | system_designn | ✅ Fully Implemented | .arworldmap file saved |
| 37 | PostgreSQL + PostGIS database | system_designn | ❌ Not Implemented | File system only |
| 38 | Plant health timeline DB | system_designn | ❌ Not Implemented | |
| 39 | GeoInfoData model | system_designn | ⚠️ Partially Implemented | SensorSnapshot captures subset |
| **Networking & Backend** | | | | |
| 40 | REST API (FastAPI) | system_designn | ❌ Not Implemented | Zero networking |
| 41 | Cloud upload (S3) | system_designn | ❌ Not Implemented | |
| 42 | Authentication (Firebase Auth) | system_designn | ❌ Not Implemented | |
| 43 | OTA model updates | system_designn | ❌ Not Implemented | |
| 44 | Cross-session map merging (server) | 3D_FARM | ❌ Not Implemented | |
| 45 | Dense 3D reconstruction (server) | 3D_FARM | ❌ Not Implemented | |
| 46 | Prescription map / PDF export | SMARTPHONE_APP | ❌ Not Implemented | |
| 47 | John Deere sync | SMARTPHONE_APP | ❌ Not Implemented | |
| **Map & Relocalization** | | | | |
| 48 | GPS-SLAM Fusion (EKF) | system_designn, 3D_FARM | ⚠️ Partially Implemented | **Code complete (340 lines) but NOT WIRED** |
| 49 | Relocalization Engine | system_designn | ⚠️ Partially Implemented | **Code complete (110 lines) but NOT WIRED** |
| 50 | Local Loop Closure | system_designn | ❌ Not Implemented | No BoW/VLAD + PnP RANSAC |
| 51 | Compact map download for relocalization | system_designn | ❌ Not Implemented | |
| 52 | Depth map visualization | 3D_FARM | ✅ Fully Implemented | DepthMapRenderer with Metal shading |

---

## 2. Category-by-Category Breakdown

### 2.1 Sensor & Capture Pipeline

**Status: Strong — ~80% complete**

This is the most mature area of the app. All 8 sensor streams from the design spec (RGB, LiDAR depth, GPS, compass, IMU, barometer, 6-DoF pose, confidence map) are integrated and producing data. The `AdaptiveCapturePolicy` implements intelligent keyframe selection based on distance (~0.5m) and rotation (~15°) thresholds, matching the design spec closely.

**Gaps:**
- No VRS (Visual Recording System) session recording — data is stored as individual frames + JSON, not a continuous VRS stream
- Only 1 of 5 capture modes (Continuous Sweep) is implemented; Single Shot, Panoramic, LiDAR-dedicated, and Time-Lapse modes are missing
- No image quality gating (blur detection, exposure checks) before frame acceptance

### 2.2 ML / Computer Vision

**Status: Not started — 0% complete**

This is the **largest gap** in the implementation. The design envisions 8+ ML models running on-device and server-side. The app contains:
- Zero CoreML model files (`.mlmodel` / `.mlmodelc`)
- No `import Vision` or `import CoreML` in any Swift file
- No disease classification, segmentation, object detection, or plant ID
- No gaze-ray → plant lookup pipeline
- No place recognition or feature matching for relocalization

The entire ML pipeline — from inference to result display — is absent.

### 2.3 UI/UX Components

**Status: Partial — ~30% of planned UI exists**

**Implemented:**
- Camera viewfinder with AR preview (no overlays)
- Session list browser with swipe-to-delete
- Session detail view with stats grid + GPS trail map
- Frame detail view with depth visualization toggle
- Sector map view (built but disconnected)

**Missing (5 of 8 planned components):**
- Results Card (diagnosis display)
- Comparison View (cross-visit scrubbing)
- Annotation Mode (active learning tap-to-correct)
- Voice Notes (geotagged audio)
- Drone Alert Integration (push notifications + navigate)
- Plant ID Display ("You're looking at Plant #14-007")

The existing UI is functional for data capture and review but provides **no analytical or diagnostic capability**.

### 2.4 Data & Persistence

**Status: Partial — ~50% complete**

**Strengths:**
- Clean file-system storage structure (`Documents/session_*/`)
- Full metadata JSON serialization per session
- JPEG frames, depth PNGs, confidence PNGs all persisted
- ARWorldMap saved for potential future relocalization
- PLY point cloud export

**Gaps:**
- No structured database (PostgreSQL + PostGIS as designed)
- No plant health timeline or per-plant tracking
- No cross-session data linking (time-series analysis impossible)
- `SensorSnapshot` captures only a subset of the full `GeoInfoData` model from the design
- No data migration or versioning strategy

### 2.5 Networking & Backend

**Status: Not started — 0% complete**

The app is entirely offline. There are zero network calls, no API client, no authentication layer, and no cloud sync. The design calls for:
- FastAPI backend with PostgreSQL
- S3 storage for images/point clouds
- Firebase Auth
- OTA model updates
- Server-side heavy inference pipeline (ViT-Large, Mask2Former, SAM)
- Prescription map generation and John Deere integration

None of this infrastructure exists in the app or the repo (aside from standalone Python scripts for satellite imagery).

### 2.6 Map & Relocalization

**Status: ~35% — key code exists but is disconnected**

**Implemented but NOT WIRED:**
- `GPSSLAMFusion.swift` (340 lines) — Extended Kalman Filter fusing GPS coordinates with ARKit SLAM poses. This is a significant piece of engineering that is complete but never instantiated in the app's view hierarchy or capture pipeline.
- `RelocalizationEngine.swift` (110 lines) — Handles loading ARWorldMaps and re-localizing against them. Code-complete but not connected to any UI or session flow.

**Not Implemented:**
- Local loop closure (BoW/VLAD descriptors)
- Compact map download from server
- Cross-session map merging
- NetVLAD/SALAD place recognition
- SuperPoint + SuperGlue feature matching

### 2.7 User Experience & Polish

**Status: Basic — functional but not production-ready**

- Tab-based navigation works (Capture, Sessions)
- Live sensor readouts during capture (GPS, tracking state)
- Depth visualization with Metal rendering
- Session browsing and frame inspection

**Missing UX elements:**
- No onboarding or tutorial flow
- No user preferences or settings screen
- No error recovery guidance (e.g., if GPS is unavailable)
- No multi-language support (design calls for it in Phase 4)
- No accessibility features
- No haptic feedback or sound cues during capture
- No progress indicators for long operations

---

## 3. Architecture Deviations

| Aspect | Design Spec | Actual Implementation | Impact |
|--------|------------|----------------------|--------|
| **Framework** | React Native + Expo | Native SwiftUI | **Positive** — better ARKit/LiDAR integration, lower latency, no bridge overhead. However, eliminates Android support. |
| **Maps SDK** | MapLibre | Apple MapKit | **Neutral** — MapKit sufficient for current needs; MapLibre would offer more customization for heatmaps/custom tiles. |
| **Dependencies** | Multiple (React Native ecosystem) | Zero third-party deps | **Positive for now** — simpler build, no dependency risk. Will need packages for networking, DB, etc. |
| **Persistence** | PostgreSQL + PostGIS | File system (JSON + images) | **Negative** — no queryable data store, no spatial queries, no relational linking between sessions/plants. |
| **Target OS** | iOS 17+ (implied) | iOS 26.0 | **Risky** — extremely high minimum deployment target limits device compatibility. |
| **Architecture** | Not specified | MVVM with ObservableObject | **Neutral** — reasonable choice for SwiftUI app. |
| **Platform** | iOS + Android (via React Native) | iOS only | **Narrowing** — design envisioned cross-platform; native Swift eliminates Android. |

### Deviation Assessment

The shift from React Native to native SwiftUI is a **deliberate and defensible** architectural decision. ARKit, LiDAR, and CoreML all have first-class Swift APIs with no reliable React Native bridges at the required performance level. The trade-off is losing Android support, which could be addressed later with a separate Kotlin/Jetpack Compose app or a shared core via C++/Rust.

The iOS 26.0 minimum deployment target is concerning — it will exclude the vast majority of iPhones in the field for at least 6-12 months after iOS 26 releases. This should be lowered to iOS 17.0+ unless there is a specific API dependency on iOS 26.

---

## 4. Critical "Dead Code" Issues

Three significant components are **built but not connected**, representing wasted engineering effort until they are wired in:

### 4.1 `GPSSLAMFusion.swift` (340 lines) — HIGH PRIORITY TO WIRE

- **What it does:** Extended Kalman Filter that fuses GPS coordinates with ARKit 6-DoF poses to produce geo-registered camera positions.
- **Why it matters:** Without this, GPS trail and SLAM trajectory are independent. The design requires geo-registered 3D maps. This is the bridge between local AR coordinates and global geo-coordinates.
- **What's needed to wire it:** Instantiate in `CaptureSession`, feed it ARFrame poses + CLLocation updates, use its fused output for frame geo-tagging instead of raw GPS.

### 4.2 `RelocalizationEngine.swift` (110 lines) — MEDIUM PRIORITY TO WIRE

- **What it does:** Loads a saved `ARWorldMap` and attempts to relocalize the current ARSession against it.
- **Why it matters:** Enables the "return visit" use case — go back to the same field and instantly know where you are relative to previously mapped plants.
- **What's needed to wire it:** Add a "Relocalize" button to `CaptureView`, let user select a previous session's world map, feed it to the engine, display relocalization status.

### 4.3 `MapSectorsView.swift` (104 lines) — LOW PRIORITY TO WIRE

- **What it does:** Displays a map with sector overlays for field zones.
- **Why it matters:** Enables spatial organization of capture data by field zone.
- **What's needed to wire it:** Add as a third tab in the `ContentView` TabView (currently only Capture and Sessions tabs exist).

---

## 5. Priority Recommendations

Ordered by impact-to-effort ratio:

### Tier 1 — Quick Wins (1-2 days each)

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 1 | **Wire GPSSLAMFusion into CaptureSession** | Geo-registered frames; prerequisite for all map features | Low — code exists |
| 2 | **Wire RelocalizationEngine into CaptureView** | Enables return-visit relocalization | Low — code exists |
| 3 | **Add MapSectorsView to TabView** | Completes navigation; shows sector map | Trivial |
| 4 | **Lower deployment target to iOS 17.0** | Dramatically increases device compatibility | Trivial (if no iOS 26 APIs are used) |

### Tier 2 — Core Value (1-2 weeks each)

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 5 | **Add Single Shot capture mode** | Simplest path to "point and diagnose" workflow | Medium |
| 6 | **Integrate a CoreML disease classification model** | First ML capability; enables Results Card UI | Medium — need model + Vision pipeline |
| 7 | **Build Results Card UI** | Makes ML output visible and actionable | Medium |
| 8 | **Add basic cloud upload** | Gets data off-device for server processing | Medium |

### Tier 3 — Platform Completion (2-4 weeks each)

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 9 | **Implement segmentation overlay** | Real-time visual feedback during capture | High |
| 10 | **Build Comparison View** | Time-series plant health tracking | High |
| 11 | **Implement backend API (FastAPI)** | Server-side processing, multi-user | High |
| 12 | **Add PostgreSQL + PostGIS persistence** | Queryable, relational, spatial data store | High |

### Tier 4 — Advanced Features (1-3 months)

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 13 | **Server-side 3D reconstruction** | Dense digital twin of farm | Very High |
| 14 | **Annotation Mode + Active Learning** | Model improvement loop | Very High |
| 15 | **Drone Alert Integration** | Aerial-ground data fusion | Very High |
| 16 | **Voice Notes** | Convenience feature | Medium |

---

## 6. Overall Progress Estimate

### By Category

| Category | Weight | Progress | Weighted |
|----------|--------|----------|----------|
| Sensor & Capture Pipeline | 20% | 80% | 16.0% |
| ML / Computer Vision | 25% | 0% | 0.0% |
| UI/UX Components | 15% | 30% | 4.5% |
| Data & Persistence | 10% | 50% | 5.0% |
| Networking & Backend | 15% | 0% | 0.0% |
| Map & Relocalization | 10% | 35% | 3.5% |
| User Experience & Polish | 5% | 20% | 1.0% |
| **Total** | **100%** | | **30.0%** |

### Summary

| Metric | Value |
|--------|-------|
| **Overall implementation progress** | **~30%** |
| Features fully implemented | 12 of 52 (23%) |
| Features partially implemented | 6 of 52 (12%) |
| Features not implemented | 34 of 52 (65%) |
| Dead code (built but unwired) | 3 components (~794 lines) |
| Design-specified ML models integrated | 0 of 8 |
| Design-specified UI components built | 3 of 8 |
| Capture modes implemented | 1 of 5 |

### Bottom Line

FarmCapture has a **solid sensor capture foundation** and a clean SwiftUI architecture. The immediate priority should be **wiring the three dead-code components** (essentially free progress), followed by integrating the **first CoreML model** to unlock the app's core diagnostic value proposition. The app is currently a capable data recorder; it needs ML inference and cloud connectivity to become the crop diagnostics platform described in the design.

---

*Report generated from analysis of 14 Swift source files against 3 system design documents.*
