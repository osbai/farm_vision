# System Design: iPhone 3D Mapping + Relocalization

## Inputs & Outputs Summary

| **Inputs** | **Source** | **iPhone API** |
|---|---|---|
| RGB frames | Rear camera | `ARFrame.capturedImage` (via ARKit) |
| Dense depth (optional) | LiDAR (Pro models) | `ARFrame.sceneDepth.depthMap` (float32, meters) + confidenceMap |
| GPS + precision | CoreLocation | `GpsData {lat, lon, horizontalAccuracy, altitude, altitudeAccuracy}` |
| Heading | Magnetometer | `CMDeviceMotion.heading` / `trueNorthHeading` |
| Orientation | CoreMotion | `CMDeviceMotion.attitude` (quaternion) |
| Altitude | Barometer + GPS | `CLLocation.altitude` + `altitudeAccuracy` |

| **Outputs** | **Description** |
|---|---|
| 3D map (refined over time) | Hierarchical pose graph with keyrigs, 3D points, descriptors, GPS tags |
| Relocalization | Re-localize against previously-built map on return visit |

---

## Online (On-iPhone, Real-Time)

These components run at 30fps on-device:

### 1. Visual-Inertial SLAM (6DoF Tracking)
**Use ARKit's platform SLAM** — it's free, optimized, and already integrated via `PlatformSLAMAlgorithm`. Gives you:
- 6DoF pose (`ARFrame.camera.transform`)
- Sparse point cloud
- Scene mesh with semantic labels (wall, floor, ceiling, table, door, window)
- LiDAR-fused dense depth (on Pro models)

**Why ARKit, not Viper?** Viper's mobile pipeline is frozen/EOL (2026), uses attitude-only (no raw IMU VIO), and doesn't ingest depth. ARKit gives you better tracking with LiDAR fusion built-in.

### 2. LiDAR Dense Depth Capture
**Already integrated** via `AKDepthTracker6DOF`:
- `sceneDepth.depthMap`: float32 per-pixel depth in meters
- `sceneDepth.confidenceMap`: per-pixel confidence (low/medium/high)
- Resolution: ~256×192 at 60fps (ARKit upsamples internally)
- Range: ~0.2m to ~5m (indoor), degrades outdoor

**Online action**: Capture depth frames, filter by confidence, store alongside keyrigs.

### 3. ARKit Scene Mesh (Coarse 3D Map)
**Already integrated** via `AKSceneTracker6DOF`:
- Incremental mesh anchors (`ARMeshAnchor`) with vertices, normals, face indices
- Semantic classification per face (8 classes)
- Updates as you scan — gives you a real-time coarse 3D map

**Online action**: Accumulate mesh anchors into a growing scene mesh. This is your **real-time 3D map preview**.

### 4. GPS + Heading Geo-Tagging
**Online action**: Tag each keyrig/keyframe with GPS + heading data. The existing `GeoInfoData` struct already supports this:
```cpp
struct GeoInfoData {
  double latitudeDeg, longitudeDeg;
  float altitudeM, horizontalUncertaintyM, verticalUncertaintyM;
  GeoInfoSource source; // GPS, WPS, MapperEstimation
};
```
**GPS is NOT used as an optimization constraint online** — just stored. GPS noise (3-10m outdoor) would hurt real-time tracking if naively fused.

### 5. Keyframe Selection + Feature Extraction
**Online action**: Select keyframes (every ~0.5m movement or ~15° rotation), extract binary descriptors (256-bit FREAK-like), store with depth and GPS tag.

### 6. Local Loop Closure
**Online action**: Detect revisited areas within the current session using place recognition (BoW/VLAD) + PnP RANSAC. Correct local drift.

### 7. VRS Recording (for Offline)
**Online action**: Record the full session to VRS format — RGB, depth, IMU, GPS, mesh. This enables offline replay and refinement.

---

## Offline (Server-Side Optimization)

These are too expensive or require cross-session data:

### 1. Global Bundle Adjustment with GPS + Depth Priors
**What**: Full BA over all keyrigs with additional error terms:
- **GPS prior**: Anchor keyrig positions to WGS84 coordinates (weighted by `horizontalUncertaintyM`)
- **Depth prior**: Constrain map point depths using LiDAR measurements
- **Gravity prior**: Already exists (`PoseGravityPriorErrorTerm`)

**Why offline?** Global BA is O(n³) in keyframes. Meta's custom optimizer (`arvr/libraries/optimizer/`) supports Schur complement + LM and is extensible — adding `GpsPriorErrorTerm` and `DepthPriorErrorTerm` follows the same pattern as existing error terms.

**New error terms needed:**
```
GpsPriorErrorTerm: ||T_ecef_keyrig - GPS_ecef|| weighted by 1/σ_gps
DepthPriorErrorTerm: ||depth_triangulated - depth_lidar|| weighted by 1/σ_depth
```

### 2. Cross-Session Map Merging
**What**: When a user scans the same area on different days, merge the maps.
**Already exists**: `CrossContextMerge` + `InContextL1FullMerge` in Viper. The system:
1. Detects overlap via place recognition (PBR/WiFi/GPS proximity)
2. Aligns maps using `MapAligner4DOF` (3D-3D RANSAC)
3. Grafts submaps from incoming context into host context
4. Re-optimizes with global BA

**Enhancement**: Use GPS proximity as a **coarse filter** to accelerate cross-session matching (avoid comparing maps from different cities).

### 3. Dense 3D Reconstruction / Mesh Refinement
**What**: Fuse all depth frames + poses into a high-quality dense mesh (TSDF, Poisson reconstruction, or neural implicit).
**Why offline?** Full volumetric fusion over thousands of frames is memory/compute intensive. Options:
- **TSDF fusion** (Open3D / voxblox style) — proven, fast on server
- **Neural surface reconstruction** (NeuS, Instant-NGP) — higher quality but GPU-heavy
- **Poisson surface reconstruction** — from dense point cloud

### 4. Texture Mapping
**What**: Project RGB images onto the refined mesh for photorealistic output.
**Why offline?** Requires optimal view selection, color correction, blending — batch process.

### 5. Map Compression + Descriptor Index Building
**What**: Compress the map for efficient relocalization:
- Build inverted visual word index for fast descriptor matching
- Prune redundant keyrigs/points
- Quantize descriptors
- Build spatial index (KD-tree / geohash) for GPS-aided retrieval

**Already partially exists**: `MapSparsifier`, `InvertedLists`, two-level quantizer.

### 6. PLY/glTF Export
**What**: Export refined mesh + texture to standard formats.
**Gap**: No PLY/glTF export exists in Viper today — would need to be added.

---

## Relocalization Flow (Return Visit)

```
                    ONLINE (iPhone)                          OFFLINE (Server)
                    ═══════════════                          ════════════════
1. User opens app
2. ARKit starts SLAM → 6DoF pose
3. Capture keyframe + GPS
4. GPS coarse filter ──────────────────→ Find candidate maps near GPS
5.                    ←────────────────── Return compact map (descriptors + 3D points)
6. Extract descriptors from current frame
7. Match against downloaded map (PnP RANSAC)
8. If match: relocalize → align current session to stored map
9. Continue tracking with drift correction
```

**Key infrastructure already exists**:
- `VegaLocalizer`: Visual word extraction → descriptor matching → RANSAC pose estimation
- `FusedSubmapListProvider`: GPS + PBR hybrid coarse search
- Cloud VPS: `RigFeaturesQuery` extraction + cloud `Relocalizer`

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     ONLINE (iPhone)                          │
│                                                              │
│  Camera ──→ ARKit SLAM ──→ 6DoF Pose ──→ Keyframe Selection │
│              │                              │                │
│  LiDAR  ──→ Dense Depth ─────────────────→ │                │
│              │                              │                │
│  GPS    ──→ GeoTag ──────────────────────→  │                │
│  Heading     │                              │                │
│  Attitude    │                              ▼                │
│              │                        Local Map              │
│              ▼                     (keyrigs + points         │
│         ARKit Mesh                  + descriptors            │
│         (real-time                  + depth + GPS)           │
│          3D preview)                     │                   │
│                                          │ VRS Recording     │
│              Relocalization ◄────────────┤                   │
│              (if map exists)             │                   │
└──────────────────────────────────────────┼───────────────────┘
                                           │ Upload
                                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    OFFLINE (Server)                           │
│                                                              │
│  VRS Replay ──→ Global BA ──→ Dense Recon ──→ Texture Map   │
│                 (+ GPS priors)  (TSDF/Neural)    │           │
│                 (+ depth priors)                  │           │
│                      │                            ▼           │
│                      ▼                     Refined 3D Mesh   │
│                Cross-Session                     │           │
│                Map Merge                         ▼           │
│                      │                     PLY/glTF Export   │
│                      ▼                                       │
│                Compact Reloc Map ──→ Descriptor Index        │
│                (for download)        + GPS spatial index     │
└─────────────────────────────────────────────────────────────┘
```

---

## Summary: What to Build vs. What Exists

| Component | Exists? | Where |
|---|---|---|
| ARKit SLAM + depth + mesh | ✅ Full | Ocean `AKDevice` + Wolf `PlatformSLAMAlgorithm` |
| GPS data flow | ✅ Full | Wolf `GpsData`, `GeoInfoData` per keyrig |
| IMU/attitude pipeline | ✅ Full | Ocean iOS sensors + Wolf `AttitudeData` |
| VRS recording | ✅ Full | Wolf `SessionRecorder` |
| Relocalization (visual) | ✅ Full | `VegaLocalizer` + PnP RANSAC |
| Place recognition | ✅ Full | BoW/VLAD + inverted index |
| Loop closure | ✅ Full | In-context + cross-context |
| Map merging | ✅ Full | `CrossContextMerge` + `InContextL1FullMerge` |
| Depth densification | ✅ Partial | `DepthDensifier` (post-hoc, not in BA) |
| GPS prior in BA | ❌ **Build** | Add `GpsPriorErrorTerm` to optimizer |
| Depth prior in BA | ❌ **Build** | Add `DepthPriorErrorTerm` to optimizer |
| Dense mesh reconstruction | ❌ **Build** | TSDF fusion or neural (server-side) |
| PLY/glTF export | ❌ **Build** | File export from refined mesh |
| GPS-aided map retrieval | ⚠️ Partial | `PosePriorSubmapListProvider` exists, needs GPS→pose bridge |
| Compact map download | ⚠️ Partial | `VegaMapFlatFile` exists, need mobile-optimized subset |

The heaviest new work is **(1)** GPS + depth error terms in the optimizer, **(2)** dense mesh reconstruction pipeline, and **(3)** compact map download/relocalization flow. Everything else can be composed from existing infrastructure.
