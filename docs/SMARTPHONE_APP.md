# 📱 Farm Vision Mobile — Smartphone-Based Field Inspection & Labeling

> A smartphone app serving as the ground-level component of the Farm Vision system — enabling farmers and agronomists to capture, diagnose, annotate, and ground-truth directly from their phone while walking fields.

The phone is the farmer's most accessible tool. By combining modern on-device ML, high-resolution cameras, LiDAR sensors, and GPS, a smartphone app can deliver instant crop diagnostics, generate geo-referenced field maps, and close the data loop between aerial/satellite imagery and boots-on-the-ground observations. This document explores architecture, UX, ML pipelines, and a phased roadmap for building that app.

---

## 📑 Table of Contents

- [🎯 Vision & Use Cases](#-vision--use-cases)
- [📸 Capture Modes](#-capture-modes)
- [🧠 On-Device ML Pipeline](#-on-device-ml-pipeline)
- [🎨 UX / App Design](#-ux--app-design)
- [🏷️ Data Collection & Labeling Strategy](#️-data-collection--labeling-strategy)
- [🛠️ Tech Stack Options](#️-tech-stack-options)
- [📱 Hardware Considerations](#-hardware-considerations)
- [🚀 MVP Roadmap](#-mvp-roadmap)
- [⚠️ Challenges & Mitigations](#️-challenges--mitigations)

---

## 🎯 Vision & Use Cases

**Primary persona:** a farmer or agronomist walking fields with their phone in hand.

The app turns a routine field walk into a rich data-collection and diagnostic session:

| Use Case | What the Farmer Does | What the App Delivers |
|---|---|---|
| **Instant Diagnosis** | Snap a photo of a leaf or plant | Disease, pest, or nutrient-deficiency classification with confidence score and recommended action |
| **Row-Level Health Map** | Walk a row while shooting video | Automated weed/crop segmentation map stitched from extracted frames |
| **Fruit Scanning** | Point LiDAR at a tree canopy | Fruit count, size distribution, and ripeness estimation via 3D point cloud |
| **Ground-Truthing** | Receive a drone/satellite alert and navigate to the flagged zone | Confirm or reject flagged anomalies, closing the loop on aerial detections |
| **In-Field Labeling** | Correct or annotate model predictions | High-quality labeled data fed back into the active learning loop for model retraining |
| **Field Scouting Log** | Tap to add geotagged notes with photos | Structured scouting reports with GPS, timestamp, weather, and observations |

---

## 📸 Capture Modes

The app supports multiple capture paradigms, each optimized for a different inspection workflow:

### Single Shot
Point-and-shoot for disease/pest classification on a single leaf or plant. The simplest mode — tap the shutter, get a diagnosis in under a second.

### Continuous Sweep
Video mode for walking along a crop row. Frames are extracted at regular intervals, analyzed individually, and stitched together into a row-level health map with per-meter annotations.

### LiDAR Scan (iPhone Pro)
Leverages the LiDAR sensor to capture a 3D point cloud of the canopy. Enables structural measurements: plant height, canopy volume, inter-plant spacing, and fruit sizing that 2D images cannot provide.

### Panoramic Field View
Wide-angle or multi-image stitch for a zone-level overview. Useful for documenting the overall state of a field section — irrigation patterns, bare patches, or color gradients indicating stress.

### Time-Lapse / Repeat Visit
The app remembers GPS positions of previous captures. Returning to the same spot triggers a side-by-side comparison to track growth, disease progression, or treatment effectiveness over days and weeks.

---

## 🧠 On-Device ML Pipeline

Running inference on-device is critical — fields often have no connectivity, and farmers need instant feedback.

### Model Architecture
- **Classification**: MobileNetV3, EfficientNet-Lite, or a distilled Vision Transformer (ViT-Tiny) for disease/pest/nutrient identification
- **Segmentation**: Mobile U-Net or DeepLabV3 with a MobileNet backbone for crop/weed/soil pixel-level masks
- **Multi-task head**: a single shared backbone feeding into parallel heads for disease classification + severity scoring + weed/crop segmentation — reducing total model size and inference cost

### Runtime
- **CoreML** — fastest on iOS, leverages the Neural Engine natively
- **TensorFlow Lite / ONNX Runtime** — cross-platform, runs on both iOS and Android
- **PyTorch Mobile** — alternative cross-platform option with strong research-to-production pipeline

### Model Updates
Over-the-air (OTA) model delivery: updated models are downloaded when the phone is on WiFi. A versioned model registry tracks which model version each device is running, enabling staged rollouts and A/B testing of new models.

### Inference Speed Targets
- **Real-time overlay** (Continuous Sweep mode): < 100 ms per frame
- **Detailed single-shot analysis**: < 500 ms end-to-end (preprocessing → inference → postprocessing → UI)

### Confidence Calibration
Models must output well-calibrated confidence scores so the app can communicate uncertainty honestly:
- *"90% confident: Late Blight"* → show diagnosis with high confidence badge
- *"45% confident — uncertain"* → prompt the farmer to capture another angle, or flag for expert review

### Fallback to Cloud
When on-device confidence falls below a configurable threshold **and** connectivity is available, the image is sent to a cloud-hosted heavier model (e.g., full ViT-Large or ensemble) for a second opinion. Results are returned and cached locally.

---

## 🎨 UX / App Design

The app must be usable with dirty hands, in bright sunlight, and by people who may not be tech-savvy. Every interaction should require minimal taps.

### Camera Viewfinder Overlay
Real-time segmentation masks or bounding boxes rendered directly on the camera feed. Color-coded regions (green = crop, red = weed, yellow = stressed) give instant visual feedback before the farmer even takes a photo.

### Results Card
After capture, a card slides up showing:
- **Diagnosis** (e.g., "Powdery Mildew")
- **Confidence score** (e.g., 92%)
- **Severity level** (Low / Medium / High)
- **Recommended action** (e.g., "Apply sulfur-based fungicide within 48h")
- **Similar reference images** from the training set for visual comparison

### Field Map View
A GPS-tracked map showing the farmer's walking path with color-coded pins:
- 🟢 **Green** — healthy
- 🟡 **Yellow** — watch / minor issue
- 🔴 **Red** — action required

Tapping a pin opens the corresponding capture and diagnosis.

### Comparison View
Side-by-side display of the same GPS location across multiple visits. Swipe to scrub through time and visualize disease progression or treatment response.

### Offline-First Architecture
Full functionality without internet. All ML models, UI assets, and recent field data are stored locally. When connectivity is restored, the app syncs captures, labels, and metadata in the background.

### Annotation Mode
The farmer can correct model predictions by tapping to relabel — e.g., changing "Healthy" to "Early Blight." These corrections feed directly into the active learning loop, producing high-value labeled data from the target domain.

### Voice Notes
Audio recording geotagged to the current location. Ideal for hands-free observations: *"Row 14, heavy aphid pressure on lower leaves, need to spray this week."* Transcribed automatically and attached to the scouting report.

### Integration with Drone Alerts
Push notification: *"Anomaly detected in Zone C — possible water stress."* Tap to open the map, navigate to the flagged zone, and inspect in person. The farmer's ground-truth observation is sent back to validate or reject the aerial detection.

---

## 🏷️ Data Collection & Labeling Strategy

The app is not just a diagnostic tool — it's a data engine that continuously improves the underlying models.

### In-Field Annotation
Every time a farmer corrects a model prediction, they produce a high-quality labeled sample from the exact domain and conditions the model operates in. This is far more valuable than lab-collected or web-scraped data.

### Active Learning Integration
The model flags its most uncertain predictions and explicitly asks the farmer to verify:
> *"Is this Cercospora Leaf Spot? Tap ✅ to confirm or ✏️ to correct."*

This targets labeling effort where it matters most — on the decision boundary where the model is weakest.

### Structured Metadata
Each capture automatically records:
- **GPS coordinates** (latitude, longitude, altitude)
- **Timestamp** (local time + UTC)
- **Weather conditions** (from phone sensors or weather API — temperature, humidity, light level)
- **Crop type and growth stage** (pre-configured per field or selected manually)
- **Device info** (model, OS version, camera settings)

### Image Quality Checks
Before an image enters the training pipeline, automated checks reject:
- Blurry images (Laplacian variance below threshold)
- Overexposed / underexposed frames
- Images with obstructed lens or fingers in frame
- Duplicates or near-duplicates

### Privacy & Consent
- Clear data ownership policies — farmers own their data
- Option for **on-device-only processing** (no data leaves the phone)
- Opt-in data sharing with anonymization for research/model improvement
- GDPR / regional compliance baked in from day one

### Data Sync
Batch upload of images + labels + metadata when connected to WiFi. Uploads are resumable, deduplicated, and compressed. A sync dashboard shows upload progress and data contribution stats.

---

## 🛠️ Tech Stack Options

| Layer | Option A | Option B | Notes |
|---|---|---|---|
| **Framework** | React Native + Expo | Swift (iOS) / Kotlin (Android) | Cross-platform vs. native performance |
| **ML Runtime** | CoreML (iOS) / TFLite (Android) | ONNX Runtime (cross-platform) | CoreML fastest on iOS; ONNX more portable |
| **LiDAR / AR** | ARKit (iOS only) | — | LiDAR limited to iPhone Pro models |
| **Maps** | MapLibre (open-source) | Mapbox SDK | MapLibre free; Mapbox more polished |
| **Backend** | FastAPI (Python) | Node.js / Express | FastAPI natural fit with ML ecosystem |
| **Database** | PostgreSQL + PostGIS | Firebase Firestore | PostGIS for spatial queries; Firestore for real-time sync |
| **Storage** | S3 / GCS | Firebase Storage | S3 for scale; Firebase for simplicity |
| **Auth** | Firebase Auth | Auth0 | Firebase simpler for mobile |

**Recommended starting stack:** React Native + Expo for rapid cross-platform iteration, CoreML on iOS / TFLite on Android for ML, FastAPI backend, PostgreSQL + PostGIS for spatial data, S3 for image storage, Firebase Auth for simplicity.

---

## 📱 Hardware Considerations

### Minimum Device
- **iPhone 12** or later (A14 Bionic — Neural Engine with 16-core ML accelerator)
- **Android** with Snapdragon 7xx+ or equivalent (Hexagon DSP for on-device inference)

### Optimal Device
- **iPhone 15 Pro** — LiDAR scanner, A17 Pro chip for fast CoreML, ProRAW for high-quality captures
- **Samsung Galaxy S24** — dedicated NPU, 200MP camera for extreme detail

### Recommended Accessories

| Accessory | Purpose | Approx. Cost |
|---|---|---|
| Macro lens clip-on | Close-up leaf inspection (trichomes, early lesions, insect eggs) | $15–$40 |
| Phone mount / chest harness | Consistent height and angle during sweep captures | $20–$50 |
| External battery pack (20,000 mAh+) | Full-day field use without charging | $25–$50 |
| Bluetooth soil probe | Paired soil moisture / pH / EC readings geotagged alongside images | $100–$300 |

---

## 🚀 MVP Roadmap

| Phase | Scope | Key Deliverables |
|---|---|---|
| **Phase 1** | Single-shot classification | Disease ID for top 10 diseases × 3 crops, geotagged field map, basic results card |
| **Phase 2** | Real-time segmentation | Camera overlay (crop/weed/soil), annotation mode for corrections |
| **Phase 3** | LiDAR + integration | Fruit counting/sizing, drone alert integration, comparison view |
| **Phase 4** | Active learning + sync | Time-series analysis, cloud sync pipeline, OTA model updates |

### Phase 1 — Foundation (Weeks 1–6)
- Train and export MobileNetV3 classifiers for top 10 diseases across wheat, corn, and grape
- Build camera capture flow with single-shot mode
- Implement results card UI with diagnosis, confidence, and recommendation
- Add GPS tracking and geotagged field map with color-coded pins
- Offline storage for captures and results

### Phase 2 — Segmentation & Annotation (Weeks 7–12)
- Train mobile DeepLabV3 for crop/weed/soil segmentation
- Build real-time camera overlay with segmentation masks
- Implement continuous sweep mode with frame extraction
- Add annotation mode — tap-to-correct labels
- Active learning: flag uncertain predictions for farmer review

### Phase 3 — LiDAR & Ecosystem Integration (Weeks 13–18)
- Integrate ARKit LiDAR for 3D point cloud capture
- Build fruit counting and sizing pipeline from point cloud data
- Implement drone/satellite alert integration with push notifications
- Add comparison view for repeat visits at the same GPS location

### Phase 4 — Data Loop & Scale (Weeks 19–24)
- Build cloud sync pipeline for images, labels, and metadata
- Implement OTA model update system with versioned registry
- Add time-series analysis and growth tracking dashboards
- Voice notes with automatic transcription
- Multi-language support (English, Spanish, Portuguese, French, Hindi)

---

## ⚠️ Challenges & Mitigations

| Challenge | Impact | Mitigation |
|---|---|---|
| **Lighting variability** | Model accuracy drops in harsh sun, shade, or overcast conditions | Heavy data augmentation during training; exposure and white-balance normalization in the preprocessing pipeline |
| **Species diversity** | Impossible to cover all crops and diseases from day one | Start with 3 key crops (wheat, corn, grape); expand incrementally based on user demand and data availability |
| **Model size vs. accuracy** | Large models deliver better accuracy but won't fit or run fast on mobile devices | Knowledge distillation from a large teacher model (ViT-Large) to a mobile student (MobileNetV3); quantization (INT8) for further size reduction |
| **Battery drain** | Continuous ML inference drains the phone battery, risking mid-field shutdowns | Optimize inference frequency (process every 5th frame in video mode); implement a battery-aware mode that reduces inference rate below 20% charge |
| **Farmer adoption** | Low tech literacy among some users; resistance to new tools | Dead-simple UX — results in < 2 taps; multilingual support; immediate value demo during onboarding; no account required for basic features |
| **Connectivity** | No internet in many rural fields | Offline-first architecture; all ML runs on-device; batch sync when WiFi is available; no feature degrades without connectivity |

---

*This document is a living brainstorm. Contributions, critiques, and wild ideas are welcome.*
