//
//  MeshGeneration.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 2/12/24.
//

import Foundation
import RealityKit
import Metal

/// Creates a small, highlightable root handle entity using an unlit additive material.
/// Useful for interactive gizmos or anchor markers in 3D space.
@MainActor
func makeRootHandleEntity() async  -> ModelEntity{
    var descriptor = UnlitMaterial.Program.Descriptor()
    descriptor.blendMode = .add
    
    let program = await UnlitMaterial.Program(descriptor: descriptor)
    let material = UnlitMaterial(program: program)
    
    let handleEntity = ModelEntity(mesh: .generateSphere(radius: 0.01), materials: [material])
    
    let hover_component = HoverEffectComponent(
        .highlight(.init(
            color: .systemBlue,
            strength: 5.0
        ))
    )
    
    handleEntity.components.set(hover_component)
    
    return handleEntity
}

/// Generates a CPU-side glyph description from a geometry-producing closure.
/// Expects equal-length position and normal arrays; otherwise logs and returns a partial result.
/// UVs are defaulted to (0, 0).
///
/// - Parameter buildGeometryFunction: A closure returning positions, normals, indices, and a bounding box.
/// - Returns: A `CPUGlyphDescription` containing packed vertices and index data.
func generateGlyphDescription(_ buildGeometryFunction : ()-> ([SIMD3<Float>], [SIMD3<Float>], [UInt16], BoundingBox)) -> CPUGlyphDescription {
    
    let (positions, normals, indices, boundingBox) = buildGeometryFunction();
    
    guard positions.count == normals.count else {
        print("Warning: Mismatched position (\(positions.count)) and normal (\(normals.count)) array lengths.")
        return .init(vertex: [], index: [], bounding_box: .init())
    }
    
    let verts = zip(positions, normals).map { (p : SIMD3<Float> , n : SIMD3<Float>) in
        ParticleVertex(
            position: MTLPackedFloat3Make(p.x, p.y, p.z),
            normal: MTLPackedFloat3Make(n.x, n.y, n.z),
            uv: (0, 0)
        )
    }
    
    return CPUGlyphDescription(vertex: verts, index: indices, bounding_box: boundingBox)
}

/// Convert a geometry patch into a CPU-side glyph descriptor.
/// - Parameter patch: The patch to convert
/// - Returns: A new CPU glyph
@MainActor
func patchToGlyph(_ patch : GeomPatch?,
                 world: NoodlesWorld) -> CPUGlyphDescription? {
    
    guard let patch else {
        default_log.error( "No patch provided.")
        return nil
    }
    
    let blankVertex : ParticleVertex = .init(
        position: MTLPackedFloat3Make(0, 0, 0),
        normal: MTLPackedFloat3Make(0, 0, 1),
        uv: (0, 0)
    )
    
    var verts: [ParticleVertex] = .init(repeating: blankVertex, count: Int(patch.vertex_count))
    
    var bounding = BoundingBox()
    
    for attribute in patch.attributes {
        guard let buffer_view = world.buffer_view_list.get(attribute.view) else {
            default_log.error("Missing buffer view for attribute \(attribute.semantic)")
            return nil
        };
        
        guard let format_stride = formatToStride(format: attribute.format) else {
            default_log.error("Unknown format for attribute \(attribute.semantic)")
            return nil
        }
        
        let actual_stride = max(attribute.stride, format_stride)
        
        guard let slice = buffer_view.get_slice(offset: attribute.offset) else {
            default_log.error("Bad slice for attribute \(attribute.semantic)")
            return nil
        }
        
        switch attribute.semantic {
        case "POSITION":
            let positions = realize_vec3(slice, .V3, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
            for p_i in 0 ..< min(positions.count, verts.count) {
                let p = positions[p_i]
                verts[p_i].position = MTLPackedFloat3Make(p.x, p.y, p.z)
                bounding = bounding.union(p)
            }
        case "NORMAL":
            let normals = realize_vec3(slice, .V3, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
            for p_i in 0 ..< min(normals.count, verts.count) {
                let n = normals[p_i]
                verts[p_i].normal = MTLPackedFloat3Make(n.x, n.y, n.z)
            }
        case "TEXTURE":
            switch attribute.format {
            case "VEC2":
                let textureCoords = realize_tex_vec2(slice, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
                for p_i in 0 ..< min(textureCoords.count, verts.count) {
                    let n = textureCoords[p_i]
                    verts[p_i].uv = (n.x, n.y)
                }
            case "U16VEC2":
                let textureCoords = realize_tex_u16vec2(slice, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
                for p_i in 0 ..< min(textureCoords.count, verts.count) {
                    let n = SIMD2<Float>(textureCoords[p_i]) / Float(UInt16.max)
                    verts[p_i].uv = (n.x, n.y)
                }
            default:
                default_log.warning("Unsupported texture format: \(attribute.format)")
                continue
            }
        default:
            default_log.warning("Unsupported semantic: \(attribute.semantic)")
            continue
        }
    }

    
    guard let index_info = patch.indices else {
        default_log.warning("Missing index info")
        return nil
    }
    
    guard let index_buff_view = world.buffer_view_list.get(index_info.view) else {
        default_log.warning("Missing index buffer view")
        return nil
    }
    
    guard let index_bytes = index_buff_view.get_slice(offset: index_info.offset) else {
        default_log.warning("Missing index buffer data")
        return nil
    }
    
    let index = realizeIndex16(index_bytes, index_info)
    
    return CPUGlyphDescription(vertex: verts, index: index, bounding_box: bounding)
}

/// Realizes (normalizes) an index buffer from raw bytes, converting to UInt16 format.
/// Supports "U8", "U16", and "U32" input formats. Strided buffers are not supported.
/// - Parameters:
///   - bytes: Raw index data buffer.
///   - indexInfo: Index format metadata.
/// - Returns: An array of UInt16 indices.
func realizeIndex16(_ bytes: Data, _ indexInfo: GeomIndex) -> [UInt16] {
    guard indexInfo.stride <= 0 else {
        default_log.error("Unable to handle strided index buffers")
        return []
    }
    
    
    return bytes.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> [UInt16] in
        switch indexInfo.format {
        case "U8":
            let arr = pointer.bindMemory(to: UInt8.self)
            return Array<UInt8>(arr).map { UInt16($0) }
            
        case "U16":
            let arr = pointer.bindMemory(to: UInt16.self)
            return Array<UInt16>(arr)

        case "U32":
            let arr = pointer.bindMemory(to: UInt32.self)
            return Array<UInt32>(arr).map { UInt16(clamping: $0) }
            
        default:
            default_log.error("Unknown index format '\(indexInfo.format)'")
            return []
        }
    }
}

/// Maps a NOODLES geometry attribute to a `LowLevelMesh.VertexSemantic`.
/// Supports position, normal, tangent, and texture channels (uv0–uv4).
/// - Parameter attribute: Geometry attribute to interpret.
/// - Returns: The matching semantic, or `nil` if unsupported.
private func determineLowLevelSemantic(attribute: GeomAttrib) -> LowLevelMesh.VertexSemantic? {
    switch attribute.semantic {
    case "POSITION":
        return .position
    case "NORMAL":
        return .normal
    case "TEXTURE":
        let semanticLookup : [LowLevelMesh.VertexSemantic] = [.uv0, .uv1, .uv2, .uv3, .uv4]
        let channel = Int(attribute.channel)
        if channel < semanticLookup.count {
            return semanticLookup[channel]
        } else {
            default_log.error("Invalid texture channel \(channel)")
            return nil
        }
    case "TANGENT":
        return .tangent
    default:
        default_log.error("Unknown semantic '\(attribute.semantic)'")
        return nil
    }
    
}

/// Maps a NOODLES format string to a Metal-compatible vertex format.
/// Only known combinations are supported.
/// - Parameter attribute: Geometry attribute with semantic and format.
/// - Returns: The corresponding `MTLVertexFormat`, or `nil` if unsupported.
private func determineLowLevelFormat(attribute: GeomAttrib) -> MTLVertexFormat? {
    switch attribute.semantic {
    case "POSITION", "NORMAL", "TANGENT":
        if attribute.format == "VEC3" {
            return .float3
        }
    case "TEXTURE":
        switch attribute.format {
        case "VEC2":
            return .float2
        case "U16VEC2":
            return .ushort2Normalized
        default:
            default_log.error("Unsupported texture format '\(attribute.format)'")
            return nil
        }
    default:
        default_log.error("Unknown semantic '\(attribute.semantic)")
        return nil
    }
    default_log.error("No matching format for semantic '\(attribute.semantic)' with format '\(attribute.format)'")
    return nil
}

//func calculateBoundingBox<T: Collection>(of points: T, position_extractor: (T.Element) -> SIMD3<Float>) -> BoundingBox? {
//    guard let first_point = points.first else {
//        return nil
//    }
//    
//    let extract_first_point = position_extractor(first_point)
//    
//    var min_point = extract_first_point
//    var max_point = extract_first_point
//    
//    for element in points {
//        let point = position_extractor(element)
//        min_point = min(min_point, point)
//        max_point = max(max_point, point)
//    }
//    
//    return BoundingBox(min: min_point, max: max_point)
//}

/// Determines the bounding box of a geometry attribute from buffer data or min/max metadata.
/// - Parameters:
///   - attribute: Geometry attribute containing position data.
///   - vertexCount: Number of vertices expected in the buffer.
///   - world: A `NoodlesWorld` context to retrieve buffer data from.
/// - Returns: The computed or declared bounding box.
@MainActor
private func determineBoundingBox(attribute: GeomAttrib,
                                  vertex_count: Int,
                                  world: NoodlesWorld) -> BoundingBox {
    
    // Prefer bounding box if it's already embedded in attribute
    if attribute.maximum_value.count > 2 && attribute.minimum_value.count > 2 {
        let min_bb = SIMD3<Float>(
            x: attribute.minimum_value[0],
            y: attribute.minimum_value[1],
            z: attribute.minimum_value[2]
        )
        
        let max_bb = SIMD3<Float>(
            x: attribute.maximum_value[0],
            y: attribute.maximum_value[1],
            z: attribute.maximum_value[2]
        )
        
        return BoundingBox(min: min_bb, max: max_bb)
    }
    
    guard let buffer_view = world.buffer_view_list.get(attribute.view) else {
        default_log.error("Failed to find buffer view for attribute")
        return BoundingBox()
    }
    
    guard let data = buffer_view.get_slice(offset: attribute.offset) else {
        default_log.error("Failed to find buffer data for attribute")
        return BoundingBox()
    }
    
    var min_bb = SIMD3<Float>(repeating: Float32.greatestFiniteMagnitude)
    var max_bb = SIMD3<Float>(repeating: -Float32.greatestFiniteMagnitude)
    
    let actual_stride = max(attribute.stride, 3*4)
    
    data.withUnsafeBytes { ptr in
        
        for p_i in 0 ..< vertex_count {
            let delta = Int(actual_stride) * p_i
            
            let point = SIMD3<Float>(
                x: ptr.loadUnaligned(fromByteOffset: delta, as: Float32.self),
                y: ptr.loadUnaligned(fromByteOffset: delta + 4, as: Float32.self),
                z: ptr.loadUnaligned(fromByteOffset: delta + 8, as: Float32.self)
            )
            
            min_bb = min(min_bb, point)
            max_bb = max(max_bb, point)
        }
    }
    
    return BoundingBox(min: min_bb, max: max_bb)
}

/// Converts a patch's primitive type string into a Metal topology type.
/// Supports points, lines, line strips, triangles, and triangle strips.
/// - Parameter patch: The patch to inspect.
/// - Returns: The Metal primitive type, or `nil` if unsupported.
private func determineIndexType(patch: GeomPatch) -> MTLPrimitiveType? {
    switch patch.type {
    case "POINTS":
        return .point
    case "LINES":
        return .line
    case "LINE_STRIP":
        return .lineStrip
    case "TRIANGLES":
        return .triangle
    case "TRIANGLE_STRIP":
        return .triangleStrip
    default:
        default_log.error("Unknown primitive type '\(patch.type)'")
        return nil
    }
}

/// Returns the byte stride for a given format string (e.g., "VEC3", "U16").
/// - Parameter format: Format string to evaluate.
/// - Returns: Byte stride for the format, or `1` as a fallback.
private func formatToStride(format: String) -> Int64? {
    switch format {
    case "U8": return 1
    case "U16": return 2
    case "U32": return 4
        
    case "U8VEC4": return 4
        
    case "U16VEC2" : return 4
        
    case "VEC2": return 2 * 4
    case "VEC3": return 3 * 4
    case "VEC4": return 4 * 4
        
    case "MAT3": return 3 * 3 * 4
    case "MAT4": return 4 * 4 * 4
    default:
        default_log.error("Unknown format '\(format)'")
        return nil
    }
}

@MainActor
func patchToLowLevelMesh(patch: GeomPatch,
                         world: NoodlesWorld) -> LowLevelMesh? {
    // MARK: - Build vertex attributes and layout mappings
    
    // these have format, layout index, offset from start of vertex data, and semantic
    var ll_attribs = [LowLevelMesh.Attribute]()
    
    // these have the buffer index, an offset to the first byte in this buffer, and a stride
    var ll_layouts = [LowLevelMesh.Layout]()
    
    // we need to pack all buffer references into the layout list
    
    struct LayoutKey : Hashable {
        let view_id : NooID
        let buffer_stride : Int64
    }
    
    var layout_mapping = [LayoutKey : Int]();
    
    var position_bounding_box: BoundingBox?;
    
    for attribute in patch.attributes {
        guard let format_stride = formatToStride(format: attribute.format) else {
            default_log.warning("Unknown format \(attribute.format), unable to build mesh")
            return nil
        }
        let actual_stride = max(attribute.stride, format_stride)
        
        // - attribute.view    this is essentially which buffer we are using
        // - attribute.offset  this is the offset to the buffer
        // - attribute.stride  this is the offset between attributes info
        
        //
        let key = LayoutKey(
            view_id: attribute.view,
            buffer_stride: actual_stride
        );
        
        guard let ll_semantic = determineLowLevelSemantic(attribute: attribute) else {
            default_log.warning("Unknown semantic \(attribute.semantic)")
            continue;
        }
        
        guard let ll_format = determineLowLevelFormat(attribute: attribute) else {
            default_log.warning("Unsupported format \(attribute.format) for semantic \(String(describing: ll_semantic))")
            continue;
        }
        
        if ll_semantic == .position {
            position_bounding_box = determineBoundingBox(attribute: attribute, vertex_count: Int(patch.vertex_count), world: world)
        }
        
        //print("SEMANTICS \(ll_semantic) \(ll_format)")
        
        // Allocate layout index if we haven't already
        let layout_index = {
            if let layout_index = layout_mapping[key] {
                return layout_index
            } else {
                let layout_index = ll_layouts.count
                layout_mapping[key] = layout_index
                ll_layouts.append(
                    LowLevelMesh.Layout(
                        bufferIndex: layout_index,  // is this correct?
                        bufferOffset: 0,
                        bufferStride: Int(key.buffer_stride))
                )
                //print("ADDING LAYOUT \(key) at index \(layout_index)")
                return layout_index
            }
        }()
        
        ll_attribs.append(
            LowLevelMesh.Attribute(
                semantic: ll_semantic,
                format: ll_format,
                layoutIndex: layout_index,
                offset: Int(attribute.offset)
            )
        )
        
    }
    
    // if we dont have a bounding box, we never had a position attrib
    
    guard let resolved_bounding_box = position_bounding_box else {
        default_log.error("Missing position semantic or failed to compute bounding box")
        return nil
    }
    
    // MARK: - Configure index format and capacity
    
    let index_format = patch.indices?.format ?? "U32"
    var index_type : MTLIndexType
    
    switch index_format {
    case "U16": index_type = .uint16
    case "U32": index_type = .uint32
    default:
        default_log.error("Unsupported index format '\(index_format)'")
        return nil
    }
    
    // MARK: - Create mesh descriptor
    
    let meshDescriptor = LowLevelMesh.Descriptor(vertexCapacity: Int(patch.vertex_count),
                                                 vertexAttributes: ll_attribs,
                                                 vertexLayouts: ll_layouts,
                                                 indexCapacity: Int(patch.indices?.count ?? 0),
                                                 indexType: index_type)
    
    // MARK: - Instantiate low-level mesh
    
    let lowLevelMesh : LowLevelMesh
    
    do {
        lowLevelMesh = try LowLevelMesh(descriptor: meshDescriptor)
    } catch {
        default_log.error("Failed to create mesh - \(error)")
        return nil
    }
    
    //dump(lowLevelMesh)
    
    // MARK: - Upload vertex buffers
    
    for (key, layout_index) in layout_mapping {
        guard let buffer_view = world.buffer_view_list.get(key.view_id) else {
            default_log.error("Missing buffer view for layout")
            return nil
        }
        
        guard let slice = buffer_view.get_slice(offset: 0) else {
            default_log.error("Missing vertex buffer data")
            return nil
        }
        
        lowLevelMesh.replaceUnsafeMutableBytes(bufferIndex: layout_index, { ptr in
            //print("Uploading mesh data \(ptr.count)")
            let res = slice.copyBytes(to: ptr)
            //print("Uploaded \(res)")
            
            default_log.info("Uploading \(res) bytes to vertex buffer \(layout_index)")
        })
    }
    
    // MARK: - Upload index buffer and finalize
    
    if let index_info = patch.indices {
        //dump(index_info)
        
        guard let buffer_view = world.buffer_view_list.get(index_info.view) else {
            default_log.error("Missing buffer view for index")
            return nil
        }
        
        guard let bytes = buffer_view.get_slice(offset: index_info.offset) else {
            default_log.error("Missing buffer data for index")
            return nil
        }
        
        lowLevelMesh.replaceUnsafeMutableIndices { ptr in
            //print("Uploading index data \(ptr.count)")
            let res = bytes.copyBytes(to: ptr)
            default_log.info("Uploading \(res) bytes to index buffer")
        }
        
        guard let index_type = determineIndexType(patch: patch) else {
            default_log.error("Failed to determine primitive type")
            return nil
        }
        
        //print("Installing index part \(index_type) bb: \(resolved_bb)")
        
        lowLevelMesh.parts.replaceAll([
            .init(
                indexOffset: 0,
                indexCount: Int(index_info.count),
                topology: index_type,
                materialIndex: 0,
                bounds: resolved_bounding_box
            )
        ])
    }
    
    return lowLevelMesh
}
