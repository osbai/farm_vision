import SwiftUI
import SceneKit

struct PointCloudView: View {
    let plyURL: URL
    @State private var isLoading = true
    @State private var vertexCount = 0

    var body: some View {
        ZStack {
            SceneKitPointCloud(plyURL: plyURL, isLoading: $isLoading, vertexCount: $vertexCount)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    if !isLoading {
                        Text("\(vertexCount) points")
                            .font(.caption)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                            .padding()
                    }
                }
                Spacer()
                if isLoading {
                    ProgressView("Loading point cloud...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
        }
        .navigationTitle("3D Map")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SceneKitPointCloud: UIViewRepresentable {
    let plyURL: URL
    @Binding var isLoading: Bool
    @Binding var vertexCount: Int

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = .black
        scnView.pointOfView = makeCamera()

        DispatchQueue.global(qos: .userInitiated).async {
            guard let (positions, colors, count, faces) = parsePLY(url: plyURL) else {
                DispatchQueue.main.async { isLoading = false }
                return
            }

            let geometry: SCNGeometry
            if let faceIndices = faces, !faceIndices.isEmpty {
                geometry = createMeshGeometry(positions: positions, colors: colors, count: count, faces: faceIndices)
            } else {
                geometry = createPointCloudGeometry(positions: positions, colors: colors, count: count)
            }

            let node = SCNNode(geometry: geometry)
            let axesNode = createAxesHelper()

            DispatchQueue.main.async {
                scnView.scene?.rootNode.addChildNode(node)
                scnView.scene?.rootNode.addChildNode(axesNode)
                vertexCount = count
                isLoading = false
            }
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func makeCamera() -> SCNNode {
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 1000
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 2, 5)
        node.look(at: SCNVector3(0, 0, 0))
        return node
    }
}

// MARK: - PLY Parser

func parsePLY(url: URL) -> (positions: [Float], colors: [UInt8], count: Int, faces: [UInt32]?)? {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let lines = content.components(separatedBy: .newlines)

    var vertexCount = 0
    var faceCount = 0
    var headerEnd = 0
    var hasColor = false

    // Parse header
    for (i, line) in lines.enumerated() {
        if line.starts(with: "element vertex") {
            vertexCount = Int(line.split(separator: " ").last ?? "0") ?? 0
        }
        if line.starts(with: "element face") {
            faceCount = Int(line.split(separator: " ").last ?? "0") ?? 0
        }
        if line.contains("property") && (line.contains("red") || line.contains("green") || line.contains("blue")) {
            hasColor = true
        }
        if line == "end_header" {
            headerEnd = i + 1
            break
        }
    }

    guard vertexCount > 0 else { return nil }

    var positions = [Float]()
    positions.reserveCapacity(vertexCount * 3)
    var colors = [UInt8]()
    colors.reserveCapacity(vertexCount * 3)

    let vertexEnd = min(headerEnd + vertexCount, lines.count)
    for i in headerEnd..<vertexEnd {
        let parts = lines[i].split(separator: " ")
        guard parts.count >= 3 else { continue }

        positions.append(Float(parts[0]) ?? 0)
        positions.append(Float(parts[1]) ?? 0)
        positions.append(Float(parts[2]) ?? 0)

        if hasColor && parts.count >= 6 {
            colors.append(UInt8(parts[3]) ?? 128)
            colors.append(UInt8(parts[4]) ?? 128)
            colors.append(UInt8(parts[5]) ?? 128)
        } else {
            colors.append(200); colors.append(200); colors.append(200)
        }
    }

    // Parse faces if present
    var faces: [UInt32]?
    if faceCount > 0 {
        var faceIndices = [UInt32]()
        faceIndices.reserveCapacity(faceCount * 3)
        let faceEnd = min(vertexEnd + faceCount, lines.count)
        for i in vertexEnd..<faceEnd {
            let parts = lines[i].split(separator: " ")
            guard parts.count >= 4 else { continue }
            // Format: "3 v0 v1 v2"
            faceIndices.append(UInt32(parts[1]) ?? 0)
            faceIndices.append(UInt32(parts[2]) ?? 0)
            faceIndices.append(UInt32(parts[3]) ?? 0)
        }
        faces = faceIndices
    }

    let actualCount = positions.count / 3
    return (positions, colors, actualCount, faces)
}

func createPointCloudGeometry(positions: [Float], colors: [UInt8], count: Int) -> SCNGeometry {
    let positionSource = SCNGeometrySource(
        data: Data(bytes: positions, count: positions.count * MemoryLayout<Float>.size),
        semantic: .vertex,
        vectorCount: count,
        usesFloatComponents: true,
        componentsPerVector: 3,
        bytesPerComponent: MemoryLayout<Float>.size,
        dataOffset: 0,
        dataStride: MemoryLayout<Float>.size * 3
    )

    let colorSource = SCNGeometrySource(
        data: Data(bytes: colors, count: colors.count),
        semantic: .color,
        vectorCount: count,
        usesFloatComponents: false,
        componentsPerVector: 3,
        bytesPerComponent: MemoryLayout<UInt8>.size,
        dataOffset: 0,
        dataStride: MemoryLayout<UInt8>.size * 3
    )

    var indices = [UInt32]()
    for i in 0..<UInt32(count) { indices.append(i) }

    let element = SCNGeometryElement(
        data: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size),
        primitiveType: .point,
        primitiveCount: count,
        bytesPerIndex: MemoryLayout<UInt32>.size
    )
    element.pointSize = 3
    element.minimumPointScreenSpaceRadius = 1
    element.maximumPointScreenSpaceRadius = 5

    return SCNGeometry(sources: [positionSource, colorSource], elements: [element])
}

func createMeshGeometry(positions: [Float], colors: [UInt8], count: Int, faces: [UInt32]) -> SCNGeometry {
    let positionSource = SCNGeometrySource(
        data: Data(bytes: positions, count: positions.count * MemoryLayout<Float>.size),
        semantic: .vertex,
        vectorCount: count,
        usesFloatComponents: true,
        componentsPerVector: 3,
        bytesPerComponent: MemoryLayout<Float>.size,
        dataOffset: 0,
        dataStride: MemoryLayout<Float>.size * 3
    )

    let colorSource = SCNGeometrySource(
        data: Data(bytes: colors, count: colors.count),
        semantic: .color,
        vectorCount: count,
        usesFloatComponents: false,
        componentsPerVector: 3,
        bytesPerComponent: MemoryLayout<UInt8>.size,
        dataOffset: 0,
        dataStride: MemoryLayout<UInt8>.size * 3
    )

    let faceCount = faces.count / 3
    let element = SCNGeometryElement(
        data: Data(bytes: faces, count: faces.count * MemoryLayout<UInt32>.size),
        primitiveType: .triangles,
        primitiveCount: faceCount,
        bytesPerIndex: MemoryLayout<UInt32>.size
    )

    let geometry = SCNGeometry(sources: [positionSource, colorSource], elements: [element])

    let material = SCNMaterial()
    material.isDoubleSided = true
    material.lightingModel = .physicallyBased
    geometry.materials = [material]

    return geometry
}

func createAxesHelper() -> SCNNode {
    let parent = SCNNode()
    let length: Float = 0.5

    func axis(color: UIColor, direction: SCNVector3) -> SCNNode {
        let cylinder = SCNCylinder(radius: 0.005, height: CGFloat(length))
        cylinder.firstMaterial?.diffuse.contents = color
        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3(direction.x * length/2, direction.y * length/2, direction.z * length/2)
        if direction.x > 0 { node.eulerAngles.z = -.pi/2 }
        if direction.z > 0 { node.eulerAngles.x = .pi/2 }
        return node
    }

    parent.addChildNode(axis(color: .red, direction: SCNVector3(1,0,0)))
    parent.addChildNode(axis(color: .green, direction: SCNVector3(0,1,0)))
    parent.addChildNode(axis(color: .blue, direction: SCNVector3(0,0,1)))
    return parent
}
