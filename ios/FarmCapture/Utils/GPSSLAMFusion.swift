import Foundation
import CoreLocation
import simd

class GPSSLAMFusion: ObservableObject {

    // MARK: - Published State

    @Published var fusionStatus: String = "Idle"
    @Published var isInitialized: Bool = false

    // MARK: - Internal State

    private var observations: [(arkitPosition: simd_float3, enuPosition: simd_float3)] = []
    private var referenceLocation: CLLocation?
    private var totalDisplacement: Float = 0
    private var lastArkitPosition: simd_float3?

    // Transform: ARKit world → ENU (set after Procrustes alignment)
    private var rotation: simd_float3x3 = matrix_identity_float3x3
    private var translation: simd_float3 = .zero

    // EKF state: [tx, ty, tz, yaw]
    private var ekfState: simd_float4 = .zero
    private var ekfCovariance: simd_float4x4 = simd_float4x4(diagonal: simd_float4(100, 100, 100, 1))

    // MARK: - Configuration

    private let minObservations = 5
    private let minDisplacement: Float = 10.0

    // MARK: - Public API

    func addObservation(arkitPose: simd_float4x4, gpsLocation: CLLocation) {
        let arkitPos = simd_float3(arkitPose.columns.3.x,
                                   arkitPose.columns.3.y,
                                   arkitPose.columns.3.z)

        if referenceLocation == nil {
            referenceLocation = gpsLocation
            DispatchQueue.main.async { self.fusionStatus = "Collecting..." }
        }

        let enuPos = wgs84ToENU(location: gpsLocation)

        if let last = lastArkitPosition {
            totalDisplacement += simd_length(arkitPos - last)
        }
        lastArkitPosition = arkitPos

        observations.append((arkitPosition: arkitPos, enuPosition: enuPos))

        if !isInitialized {
            if observations.count >= minObservations && totalDisplacement >= minDisplacement {
                DispatchQueue.main.async { self.fusionStatus = "Initializing..." }
                computeAlignment()
                initializeEKF()
                DispatchQueue.main.async {
                    self.isInitialized = true
                    self.fusionStatus = "Active ✓"
                }
            }
        } else {
            let prevObs = observations[observations.count - 2]
            let arkitDelta = arkitPos - prevObs.arkitPosition
            ekfPredict(arkitDelta: arkitDelta)
            ekfUpdate(gpsENU: enuPos, accuracy: Float(gpsLocation.horizontalAccuracy))
        }
    }

    func arkitToWGS84(arkitPosition: simd_float3) -> CLLocationCoordinate2D? {
        guard isInitialized else { return nil }
        let enu = applyTransform(arkitPosition)
        return enuToWGS84(enu: enu)
    }

    func wgs84ToArkit(coordinate: CLLocationCoordinate2D) -> simd_float3? {
        guard isInitialized, let ref = referenceLocation else { return nil }
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let enu = wgs84ToENU(location: loc)
        return applyInverseTransform(enu)
    }

    var currentGeoPosition: CLLocationCoordinate2D? {
        guard isInitialized, let lastArkit = lastArkitPosition else { return nil }
        return arkitToWGS84(arkitPosition: lastArkit)
    }

    // MARK: - Transform Application

    private func applyTransform(_ arkitPos: simd_float3) -> simd_float3 {
        let yaw = ekfState.w
        let cosY = cos(yaw)
        let sinY = sin(yaw)
        let R = simd_float3x3(rows: [
            simd_float3(cosY, 0, sinY),
            simd_float3(0, 1, 0),
            simd_float3(-sinY, 0, cosY)
        ])
        let t = simd_float3(ekfState.x, ekfState.y, ekfState.z)
        return R * arkitPos + t
    }

    private func applyInverseTransform(_ enuPos: simd_float3) -> simd_float3 {
        let yaw = ekfState.w
        let cosY = cos(yaw)
        let sinY = sin(yaw)
        let R_inv = simd_float3x3(rows: [
            simd_float3(cosY, 0, -sinY),
            simd_float3(0, 1, 0),
            simd_float3(sinY, 0, cosY)
        ])
        let t = simd_float3(ekfState.x, ekfState.y, ekfState.z)
        return R_inv * (enuPos - t)
    }

    // MARK: - WGS84 ↔ ENU Conversion

    private func wgs84ToENU(location: CLLocation) -> simd_float3 {
        guard let ref = referenceLocation else { return .zero }
        let refLat = ref.coordinate.latitude * .pi / 180.0
        let dLon = location.coordinate.longitude - ref.coordinate.longitude
        let dLat = location.coordinate.latitude - ref.coordinate.latitude

        let east = Float(dLon * cos(refLat) * 111319.5)
        let north = Float(dLat * 111319.5)
        let up = Float(location.altitude - ref.altitude)

        return simd_float3(east, up, north)
    }

    private func enuToWGS84(enu: simd_float3) -> CLLocationCoordinate2D {
        guard let ref = referenceLocation else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        let refLat = ref.coordinate.latitude * .pi / 180.0
        let east = Double(enu.x)
        let north = Double(enu.z)

        let lat = ref.coordinate.latitude + north / 111319.5
        let lon = ref.coordinate.longitude + east / (cos(refLat) * 111319.5)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Procrustes Alignment (Yaw-Only Rigid Transform)

    private func computeAlignment() {
        guard observations.count >= minObservations else { return }

        // Compute centroids
        var arkitCentroid = simd_float3.zero
        var enuCentroid = simd_float3.zero
        for obs in observations {
            arkitCentroid += obs.arkitPosition
            enuCentroid += obs.enuPosition
        }
        let n = Float(observations.count)
        arkitCentroid /= n
        enuCentroid /= n

        // Cross-covariance for yaw (2D: XZ plane for ARKit → East/North for ENU)
        // ARKit: x = right, z = forward (negated); ENU: x = east, z = north
        var cxx: Float = 0; var cxz: Float = 0
        var czx: Float = 0; var czz: Float = 0
        for obs in observations {
            let a = obs.arkitPosition - arkitCentroid
            let e = obs.enuPosition - enuCentroid
            cxx += a.x * e.x
            cxz += a.x * e.z
            czx += a.z * e.x
            czz += a.z * e.z
        }

        // Optimal yaw via atan2 on the 2×2 SVD (closed-form for 2D)
        let yaw = atan2(czx - cxz, cxx + czz)
        let cosY = cos(yaw)
        let sinY = sin(yaw)

        rotation = simd_float3x3(rows: [
            simd_float3(cosY, 0, sinY),
            simd_float3(0, 1, 0),
            simd_float3(-sinY, 0, cosY)
        ])
        translation = enuCentroid - rotation * arkitCentroid

        // Initialize EKF state from Procrustes result
        ekfState = simd_float4(translation.x, translation.y, translation.z, yaw)
    }

    // MARK: - EKF

    private func initializeEKF() {
        let initialUncertainty: Float = 10.0
        ekfCovariance = simd_float4x4(diagonal: simd_float4(
            initialUncertainty,
            initialUncertainty,
            initialUncertainty,
            0.1
        ))
    }

    private func ekfPredict(arkitDelta: simd_float3) {
        // State prediction: transform doesn't change (constant model)
        // The transform itself is the state — ARKit odometry drives position change,
        // but the alignment parameters (tx, ty, tz, yaw) stay constant.
        // Add process noise to allow slow drift.

        let processNoise: Float = 0.001
        let yawNoise: Float = 0.0001
        let Q = simd_float4x4(diagonal: simd_float4(processNoise, processNoise, processNoise, yawNoise))
        ekfCovariance = ekfCovariance + Q
    }

    private func ekfUpdate(gpsENU: simd_float3, accuracy: Float) {
        guard let lastArkit = lastArkitPosition else { return }

        // Predicted ENU from current ARKit position + current transform
        let predictedENU = applyTransform(lastArkit)

        // Innovation (measurement residual)
        let innovation = gpsENU - predictedENU

        // Measurement noise from GPS accuracy (meters²)
        let gpsVariance = max(accuracy * accuracy, 1.0)

        // Jacobian H: d(predicted_enu)/d(state)
        // predicted = R(yaw) * arkit + t
        // ∂/∂tx = [1,0,0], ∂/∂ty = [0,1,0], ∂/∂tz = [0,0,1]
        // ∂/∂yaw = dR/dyaw * arkit
        let yaw = ekfState.w
        let cosY = cos(yaw)
        let sinY = sin(yaw)
        let ax = lastArkit.x
        let az = lastArkit.z

        let dRdYaw_arkit = simd_float3(
            -sinY * ax + cosY * az,
            0,
            -cosY * ax - sinY * az
        )

        // H is 3×4: [I₃ | dRdYaw_arkit]
        // S = H * P * Hᵀ + R_meas
        // K = P * Hᵀ * S⁻¹

        // Compute S (3×3) manually
        let P = ekfCovariance
        var S = simd_float3x3(0)
        // S = H * P * Hᵀ + R
        // H = [I₃ | d], where d = dRdYaw_arkit (column vector)
        // H*P = [P[0..2, 0..2] + d * P[3, 0..2]; etc.]

        // Simpler: compute PH^T (4×3), then S = H * PH^T + R
        // PH^T columns: for measurement dim i, PH^T[:,i] = P * H[i,:]^T
        // H[0,:] = [1,0,0, d.x]
        // H[1,:] = [0,1,0, d.y]
        // H[2,:] = [0,0,1, d.z]
        let d = dRdYaw_arkit

        let PHt_col0 = simd_float4(
            P.columns.0.x + d.x * P.columns.3.x,
            P.columns.0.y + d.x * P.columns.3.y,
            P.columns.0.z + d.x * P.columns.3.z,
            P.columns.0.w + d.x * P.columns.3.w
        )
        let PHt_col1 = simd_float4(
            P.columns.1.x + d.y * P.columns.3.x,
            P.columns.1.y + d.y * P.columns.3.y,
            P.columns.1.z + d.y * P.columns.3.z,
            P.columns.1.w + d.y * P.columns.3.w
        )
        let PHt_col2 = simd_float4(
            P.columns.2.x + d.z * P.columns.3.x,
            P.columns.2.y + d.z * P.columns.3.y,
            P.columns.2.z + d.z * P.columns.3.z,
            P.columns.2.w + d.z * P.columns.3.w
        )

        // S = H * PH^T + R  (3×3)
        // H * PHt_col_j gives S[:,j]
        // H[i,:] · PHt_col_j = PHt_col_j[i] + d[i] * PHt_col_j[3]
        S.columns.0 = simd_float3(
            PHt_col0.x + d.x * PHt_col0.w + gpsVariance,
            PHt_col0.y + d.y * PHt_col0.w,
            PHt_col0.z + d.z * PHt_col0.w
        )
        S.columns.1 = simd_float3(
            PHt_col1.x + d.x * PHt_col1.w,
            PHt_col1.y + d.y * PHt_col1.w + gpsVariance,
            PHt_col1.z + d.z * PHt_col1.w
        )
        S.columns.2 = simd_float3(
            PHt_col2.x + d.x * PHt_col2.w,
            PHt_col2.y + d.y * PHt_col2.w,
            PHt_col2.z + d.z * PHt_col2.w + gpsVariance
        )

        // Invert S (3×3)
        let Sinv = S.inverse

        // Kalman gain K = PH^T * S⁻¹  (4×3)
        // K[:,j] = PHt * Sinv[:,j]  — but we have PHt as columns, need rows
        // K[i,j] = sum_k PHt[i,k] * Sinv[k,j]
        // PHt row i = (PHt_col0[i], PHt_col1[i], PHt_col2[i])
        func kalmanRow(_ i: Int) -> simd_float3 {
            let pht_row = simd_float3(PHt_col0[i], PHt_col1[i], PHt_col2[i])
            return simd_float3(
                simd_dot(pht_row, Sinv.columns.0),
                simd_dot(pht_row, Sinv.columns.1),
                simd_dot(pht_row, Sinv.columns.2)
            )
        }
        let K0 = kalmanRow(0)
        let K1 = kalmanRow(1)
        let K2 = kalmanRow(2)
        let K3 = kalmanRow(3)

        // State update: x = x + K * innovation
        ekfState.x += simd_dot(K0, innovation)
        ekfState.y += simd_dot(K1, innovation)
        ekfState.z += simd_dot(K2, innovation)
        ekfState.w += simd_dot(K3, innovation)

        // Covariance update: P = (I - K*H) * P
        // KH is 4×4: KH[i,j] = sum_k K[i,k] * H[k,j]
        // H[:,0] = [1,0,0]^T, H[:,1] = [0,1,0]^T, H[:,2] = [0,0,1]^T, H[:,3] = [d.x,d.y,d.z]^T
        func khRow(_ kr: simd_float3) -> simd_float4 {
            return simd_float4(kr.x, kr.y, kr.z,
                               kr.x * d.x + kr.y * d.y + kr.z * d.z)
        }
        let KH = simd_float4x4(rows: [
            khRow(K0), khRow(K1), khRow(K2), khRow(K3)
        ])

        let I4 = matrix_identity_float4x4
        let ImKH = I4 - KH
        ekfCovariance = ImKH * P
    }
}
