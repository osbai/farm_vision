# 🗺️ 3D Farm Mapping — iPhone Sensor Fusion for Plant-Level Localization

> **Goal:** Walk through a farm with an iPhone, and the system builds a persistent 3D map of the farm. Every photo taken is precisely localized in 3D space, and combined with gaze/orientation, the system knows exactly which plant the user is looking at. This enables per-plant tracking over time — a true digital twin of the farm at individual plant resolution.

---

## Table of Contents

- [📡 Available iPhone Sensors & What They Give Us](#-available-iphone-sensors--what-they-give-us)
  - [GPS (CoreLocation)](#gps-corelocation)
  - [LiDAR (ARKit, iPhone Pro)](#lidar-arkit-iphone-pro)
  - [IMU (Accelerometer + Gyroscope)](#imu-accelerometer--gyroscope)
  - [Magnetometer (Compass)](#magnetometer-compass)
  - [Camera (RGB)](#camera-rgb)
  - [Barometer](#barometer)
  - [ARKit World Tracking](#arkit-world-tracking)
- [🏗️ Building the 3D Farm Map](#️-building-the-3d-farm-map)
  - [Phase 1: Initial Map Creation](#phase-1-initial-map-creation-first-walk-through)
  - [Phase 2: Map Refinement & SfM](#phase-2-map-refinement--structure-from-motion)
  - [Phase 3: Plant Instance Mapping](#phase-3-plant-instance-mapping)
  - [Phase 4: Map Maintenance & Updates](#phase-4-map-maintenance--updates)
- [📷 Photo × Gaze: Knowing Which Plant You're Looking At](#-photo--gaze-knowing-which-plant-youre-looking-at)
- [🔄 Relocalization: Coming Back to the Same Spot](#-relocalization-coming-back-to-the-same-spot)
- [🌱 Per-Plant Tracking Over Time](#-per-plant-tracking-over-time)
- [⚙️ Technical Architecture](#️-technical-architecture)
- [🎯 Accuracy Budget](#-accuracy-budget)
- [⚡ Online vs. Offline Processing](#-online-vs-offline-processing)
  - [Real-Time On-Device (Online)](#real-time-on-device-online)
  - [Post-Processing (Offline)](#post-processing-offline)
  - [The Handoff: Online → Offline](#the-handoff-online--offline)
  - [The Guiding Principle](#the-guiding-principle)
- [⚠️ Challenges](#️-challenges)
- [🚀 MVP for 3D Mapping](#-mvp-for-3d-mapping)

---

## 📡 Available iPhone Sensors & What They Give Us

### GPS (CoreLocation)

| Mode | Accuracy | Notes |
|---|---|---|
| Raw GPS | ±5 m | Not sufficient for plant-level localization |
| RTK-corrected GPS | ±2 cm | Requires external RTK receiver (e.g., Emlid Reach) |
| Fused location (GPS + WiFi + cell) | ±3–10 m | Best available without hardware add-ons |
| Differential GPS with SBAS | ±1–3 m | Moderate improvement over raw |

**Use case:** Coarse position, field-level localization, starting point for refinement.

### LiDAR (ARKit, iPhone Pro)

- Time-of-flight depth sensor, range **0–5 m**
- Generates dense depth maps at **256×192** resolution
- Combined with RGB camera for colored point clouds
- ARKit scene reconstruction: real-time mesh generation

**Use case:** Local 3D structure, plant geometry, canopy shape.

### IMU (Accelerometer + Gyroscope)

- 6-axis inertial measurement at **100 Hz**
- **Accelerometer:** linear acceleration in 3 axes
- **Gyroscope:** angular velocity in 3 axes
- Core Motion sensor fusion: attitude (roll, pitch, yaw), gravity vector, user acceleration

**Use case:** Dead reckoning between GPS fixes, smooth trajectory estimation.

### Magnetometer (Compass)

- Heading relative to magnetic north
- Combined with accelerometer for tilt-compensated heading

**Use case:** Absolute orientation reference, gaze direction.

### Camera (RGB)

- 12–48 MP main camera, ultra-wide, telephoto
- Video at 4K/60fps or 1080p/240fps
- EXIF data: focal length, exposure, timestamp

**Use case:** Visual odometry, feature matching, photo localization.

### Barometer

- Relative altitude changes with **~10 cm** precision

**Use case:** Elevation tracking on hilly terrain, row elevation profiling.

### ARKit World Tracking

- Fuses **Camera + IMU + LiDAR** into 6-DoF pose estimation
- **Visual-Inertial Odometry (VIO):** camera features + IMU for smooth tracking
- **World anchors:** persistent points in 3D space
- **Plane detection:** ground plane, vertical surfaces

**Use case:** THE key integration layer — gives real-time 6-DoF pose at 60 Hz.

---

## 🏗️ Building the 3D Farm Map

### Phase 1: Initial Map Creation (First Walk-Through)

1. Farmer walks through rows with iPhone in hand or mounted on chest
2. ARKit provides continuous **6-DoF pose** (position + orientation) at 60 Hz
3. LiDAR captures depth at each frame → generates local point clouds
4. Point clouds are registered into a global coordinate frame using ARKit's world tracking
5. GPS provides coarse georeferencing (anchor the ARKit map to real-world coordinates)

**Output:** Georeferenced 3D point cloud of the farm with per-row structure.

### Phase 2: Map Refinement & Structure from Motion

1. Extract visual features (**SuperPoint**, SIFT) from captured frames
2. Run **bundle adjustment** to refine camera poses and 3D point positions
3. Merge LiDAR depth with SfM sparse reconstruction for dense map
4. Segment the map into semantic regions: rows, pathways, individual plant locations
5. Register to satellite/drone orthomosaic for absolute positioning

### Phase 3: Plant Instance Mapping

1. Detect individual plants in the 3D map using **clustering on the point cloud**
2. Assign each plant a **unique ID** + 3D centroid position
3. Build a plant database: `PlantID → (lat, lon, elevation, row, position_in_row)`
4. Store canonical appearance (multi-view images from first walk-through)

**Output:** The persistent "digital twin" of the farm.

### Phase 4: Map Maintenance & Updates

- On subsequent visits, **relocalize** against the existing map (visual place recognition)
- Detect changes: new plants, removed plants, growth, damage
- **Incremental map updates** without full reconstruction
- Seasonal adjustments: the map evolves with crop growth stages

---

## 📷 Photo × Gaze: Knowing Which Plant You're Looking At

### The Localization Problem

When the farmer takes a photo, we need to answer: **"Which specific plant is in this photo?"**

### Step 1: Camera Pose from ARKit

- ARKit gives the **6-DoF pose** (x, y, z, roll, pitch, yaw) at the moment of capture
- This tells us **WHERE** the phone is and **WHICH DIRECTION** it's pointing
- Accuracy: ~1–5 cm position, ~1° orientation (in well-tracked conditions)

### Step 2: Gaze Ray Casting

- From the camera pose, compute the **gaze ray** (center of the camera's field of view)
- Cast this ray into the 3D farm map
- Find the intersection with the plant point cloud / mesh
- The nearest plant to the intersection point = the plant being looked at

### Step 3: Depth-Assisted Refinement

- LiDAR provides real-time depth → we know exactly how far the target is
- Combine gaze ray + depth = **precise 3D point of interest**
- Match this 3D point against the plant database to find the specific `PlantID`

### Step 4: Visual Confirmation

- Crop the photo around the detected plant region
- Run visual matching against the plant's stored canonical appearance
- Confirm or correct the `PlantID` assignment
- Handle edge cases: multiple plants in frame, partially occluded plants

### The Math (Simplified)

```text
Camera pose: T = [R | t]  (rotation matrix R, translation vector t)
Gaze direction: g = R * [0, 0, 1]^T  (camera z-axis in world frame)
Ray: P(d) = t + d * g  (parametric ray, d = distance along ray)
LiDAR depth at center pixel: d_lidar
Target 3D point: P_target = t + d_lidar * g
Nearest plant: argmin_i || P_target - PlantCentroid_i ||
```

---

## 🔄 Relocalization: Coming Back to the Same Spot

### Visual Place Recognition

- On return visits, match current camera frames against stored map keyframes
- Use **NetVLAD**, **SALAD**, or similar retrieval method for coarse localization
- Refine with local feature matching (**SuperPoint + SuperGlue / LightGlue**)
- Recover precise 6-DoF pose relative to the existing map

### GPS-Primed Relocalization

- Use GPS to narrow the search area (don't match against the entire farm)
- GPS says *"you're in zone C, row 14"* → only match against that region's keyframes
- Dramatically reduces search time and false matches

### Handling Changes Between Visits

- Plants grow, leaves change, seasons shift — appearance changes
- Use **geometric structure** (row spacing, plant spacing) as a stable anchor
- Combine appearance matching with spatial priors: *"I'm at row 14, position 7, so this should be Plant #14-007"*

---

## 🌱 Per-Plant Tracking Over Time

### Plant Health Timeline

- Each `PlantID` accumulates observations over time
- Timeline: `[(date1, photo1, diagnosis1), (date2, photo2, diagnosis2), ...]`
- Track: disease progression, growth rate, treatment response
- Alert: *"Plant #14-007 showed early blight on March 15, treated March 16, check status"*

### Growth Modeling

- LiDAR measurements over time → **plant height curve**, canopy volume growth
- Compare against expected growth model for the crop variety
- Flag outliers: stunted growth, abnormal canopy shape

### Spatial Analysis

- **Disease spread patterns:** *"Blight started at Plant #14-007 and spread to neighboring plants over 2 weeks"*
- **Yield prediction:** per-plant fruit count × size estimation
- **Treatment effectiveness:** compare treated vs. untreated plants in the same row

---

## ⚙️ Technical Architecture

### On-Device Pipeline

```text
Sensors (GPS + IMU + LiDAR + Camera)
    │
    ▼
ARKit World Tracking (6-DoF pose @ 60Hz)
    │
    ├──► Point Cloud Builder (LiDAR depth → 3D map)
    │
    ├──► Photo Localizer (pose + gaze → PlantID)
    │
    └──► Local Map Cache (on-device SQLite + point cloud)
```

### Cloud Pipeline

```text
On-Device Map Fragments
    │  (WiFi sync)
    ▼
Map Server (merge, optimize, bundle adjustment)
    │
    ├──► Global Farm Map (PostGIS + 3D tiles)
    │
    ├──► Plant Database (PlantID → location + history)
    │
    └──► ML Pipeline (retrain models with new labeled data)
```

### Key Libraries / Frameworks

| Component | Library | Platform |
|---|---|---|
| 6-DoF Tracking | ARKit (`ARWorldTrackingConfiguration`) | iOS |
| LiDAR Depth | ARKit (`ARDepthData`) | iOS Pro |
| Point Cloud Processing | Metal / Accelerate framework | iOS |
| Visual Features | SuperPoint (CoreML) | iOS |
| Feature Matching | SuperGlue / LightGlue (CoreML) | iOS |
| Bundle Adjustment | Ceres Solver (C++, cross-compiled) or custom | Cross |
| Place Recognition | NetVLAD / SALAD (CoreML) | iOS |
| Spatial Database | SQLite + R-tree index | iOS |
| Cloud Map | PostGIS + 3D Tiles (Cesium) | Server |
| Visualization | SceneKit or RealityKit | iOS |

---

## 🎯 Accuracy Budget

| Component | Error Source | Expected Accuracy |
|---|---|---|
| GPS (raw) | Satellite geometry, multipath | ±5 m |
| GPS (RTK) | Corrected | ±2 cm |
| ARKit VIO | Drift over distance | ~1% of distance traveled |
| ARKit + LiDAR | Depth + pose | ±1–5 cm locally |
| Gaze ray | Orientation error | ±1–2° → ±2–5 cm at 2 m distance |
| Plant matching | PlantID assignment | ~95%+ with geometric priors |
| **End-to-end** | **"Which plant am I looking at?"** | **±5–10 cm** (sufficient for plant spacing >30 cm) |

---

## ⚡ Online vs. Offline Processing

### Real-Time On-Device (Online)

These run live as the farmer walks, at 30–60Hz:

#### Sensor Fusion & Tracking

- **ARKit VIO** — 6-DoF pose from camera + IMU + LiDAR, runs natively at 60Hz
- **GPS reading** — coarse position updates at 1Hz
- **IMU integration** — dead reckoning between frames at 100Hz
- **Compass heading** — absolute orientation reference
- **Barometer** — relative altitude changes

#### Local 3D Reconstruction

- **LiDAR depth capture** — 256×192 depth map per frame, native hardware
- **ARKit mesh generation** — real-time scene mesh (coarse but fast)
- **Local point cloud accumulation** — stitch last N frames into a local 3D patch
- **Ground plane detection** — ARKit handles this natively

#### Photo Capture & Gaze

- **Camera pose at shutter** — instantly available from ARKit
- **Gaze ray computation** — trivial math, microseconds
- **LiDAR depth at center pixel** — instant readout → 3D point of interest
- **Nearest plant lookup** — spatial query on R-tree index (~1ms) if plant database is loaded locally

#### Lightweight ML Inference

- **Disease classification** — MobileNetV3/EfficientNet-Lite on a single photo, ~50–100ms on Neural Engine
- **Real-time segmentation** — mobile U-Net for crop/weed/soil overlay, ~30–80ms per frame (can do 15fps)
- **Confidence scoring** — from model output, negligible cost
- **Image quality check** — blur detection, exposure check, ~5ms

#### UX Feedback

- **Camera overlay** — segmentation mask rendered on viewfinder in real-time
- **Results card** — instant disease diagnosis after photo capture
- **GPS pin drop** — mark current location on field map
- **Plant identification** — "You're looking at Plant #14-007" shown immediately if map is loaded

### Post-Processing (Offline)

These are too expensive, too data-hungry, or require global context:

#### Global Map Construction

- **Bundle adjustment** — optimizes ALL camera poses + 3D points jointly. O(n³) in the number of views. A 30-min walk = thousands of frames → minutes to hours on a server
- **Loop closure** — detecting when you've returned to a previously visited spot and correcting accumulated drift. Requires matching against full map database
- **Global point cloud merging** — stitching local patches into one consistent farm map. Memory-intensive (millions of points)
- **Georeferencing alignment** — registering the ARKit map to GPS/satellite coordinates with optimization

#### Dense Reconstruction

- **Multi-view stereo** — computing dense depth from many overlapping images. Far more accurate than single-frame LiDAR but extremely compute-heavy
- **Surface reconstruction** — converting point cloud to watertight mesh (Poisson reconstruction). CPU-intensive
- **Texture mapping** — projecting high-res photos onto the 3D mesh for photorealistic visualization

#### Plant Instance Segmentation

- **3D clustering** — segmenting the point cloud into individual plants. Requires the full merged map
- **PlantID assignment** — assigning unique IDs based on row structure + spacing. Needs global context
- **Canonical appearance extraction** — selecting the best multi-view images per plant from all captured data

#### Heavy ML Processing

- **Large model inference** — running ViT-Large, Mask2Former, or foundation models (SAM, DINOv2) on the full image set. Too slow for real-time on phone
- **Ensemble / second opinion** — running multiple models and aggregating predictions for higher accuracy
- **Temporal analysis** — comparing current visit against previous visits for change detection. Requires historical data access

#### Active Learning Pipeline

- **Uncertainty mining** — finding the most informative samples from the day's captures for labeling
- **Model retraining** — fine-tuning on newly labeled data. GPU-intensive
- **Model validation** — evaluating updated model on held-out test set
- **OTA model packaging** — exporting to CoreML/TFLite, testing, and pushing to devices

#### Reporting & Integration

- **Prescription map generation** — aggregating all zone-level predictions into actionable application maps
- **Farm management sync** — pushing data to John Deere / Climate FieldView APIs
- **PDF/email reports** — generating scouting reports with maps, photos, and recommendations
- **Multi-user map merging** — if multiple people walk different parts of the farm, merging their maps

### The Handoff: Online → Offline

```text
FIELD (Online)                          BACK AT BASE (Offline)
─────────────────                       ──────────────────────
ARKit poses (60Hz)  ──┐
LiDAR depths        ──┤                 Bundle Adjustment
RGB frames          ──┼── save to ──►   Dense Reconstruction
GPS fixes           ──┤   local         Plant Segmentation
IMU data            ──┘   storage       Global Map Merge
                                              │
Quick diagnosis     ◄── instant              │
Gaze → PlantID      ◄── instant              ▼
Segmentation overlay ◄── instant        Updated Plant DB
                                        Retrained Models
                                        Prescription Maps
                                              │
                          WiFi sync ◄─────────┘
                              │
                              ▼
                    Next visit: better map,
                    better models, richer
                    plant histories
```

### The Guiding Principle

| | Online | Offline |
|---|---|---|
| **Scope** | Local (current frame, nearby plants) | Global (entire farm, full history) |
| **Latency** | < 100ms | Minutes to hours acceptable |
| **Data needed** | Current sensor readings | All accumulated data |
| **Compute** | Neural Engine + GPU (phone) | Server GPU/CPU cluster |
| **User value** | Instant feedback in the field | Better accuracy, maps, insights |

The farmer gets **immediate value** in the field (diagnosis, plant ID, overlay), and **deeper insights** arrive later after offline processing. Each visit makes the system smarter — the offline pipeline refines the map and models, which improves the next online session.

---

## ⚠️ Challenges

| Challenge | Details | Mitigation |
|---|---|---|
| ARKit drift | VIO drifts over long walks (100 m+) | Periodic GPS anchoring; loop closure when revisiting areas |
| Outdoor tracking | ARKit designed for indoor; fewer features in fields | Leverage row structure as geometric prior; ground plane detection |
| Sunlight / glare | Harsh lighting affects camera tracking | HDR capture; track in early morning / late afternoon |
| GPS multipath | Trees / structures cause GPS errors | Use GPS only for coarse priming, not fine localization |
| Plant occlusion | Dense canopy hides individual plants | Use row structure + spacing model to infer hidden plant positions |
| Scale | Full farm map = massive point cloud | LOD (level-of-detail) management; tile-based streaming |
| Season changes | Appearance changes drastically | Geometric anchors (row/spacing) over appearance; periodic re-mapping |

---

## 🚀 MVP for 3D Mapping

### Phase 1 — Single Row Proof of Concept

- Single row mapping with ARKit + LiDAR
- Manual plant tagging (tap on screen to mark plant positions)
- Gaze-based photo-to-plant association
- Basic relocalization on return visit

### Phase 2 — Multi-Row Farm Mapping

- Multi-row farm mapping with GPS georeferencing
- Automatic plant detection and ID assignment from point cloud
- Visual place recognition for instant relocalization

### Phase 3 — Full Farm Digital Twin

- Full farm digital twin with per-plant timelines
- Cloud sync and multi-device support
- Integration with drone / satellite data layers
