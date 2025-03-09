//
//  MeshGeneration.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 2/12/24.
//

import Foundation
import RealityKit
import Metal

func make_root_handle() async  -> ModelEntity{
    var descriptor = UnlitMaterial.Program.Descriptor()
    
    descriptor.blendMode = .add
    
    let program = await UnlitMaterial.Program(descriptor: descriptor)
    
    let material = UnlitMaterial(program: program)
    
    let handle_entity = await ModelEntity(mesh: .generateSphere(radius: 0.01), materials: [material])
    
    await handle_entity.components.set(HoverEffectComponent(
        .highlight(.init(
            color: .systemBlue,
            strength: 5.0
        ))
    ))
    
    return handle_entity
}

func make_glyph(_ f : ()-> ([SIMD3<Float>], [SIMD3<Float>], [UInt16], BoundingBox)) -> CPUGlyphDescription {
    
    let (pos, nors, index, bb) = f();
    
    let verts = zip(pos, nors).map { (p : SIMD3<Float> , n : SIMD3<Float>) in
        ParticleVertex(position: MTLPackedFloat3Make(p.x, p.y, p.z), normal: MTLPackedFloat3Make(n.x, n.y, n.z), uv: (0, 0))
    }
    
    return CPUGlyphDescription(vertex: verts, index: index, bounding_box: bb)
}


@MainActor
func patch_to_glyph(_ p : GeomPatch?,
                    world: NoodlesWorld) -> CPUGlyphDescription? {
    
    guard let patch = p else {
        return nil
    }
    
    let blank_vertex : ParticleVertex = .init(
        position: MTLPackedFloat3Make(0, 0, 0),
        normal: MTLPackedFloat3Make(0, 0, 1),
        uv: (0, 0)
    )
    
    var verts: [ParticleVertex] = .init(repeating: blank_vertex, count: Int(patch.vertex_count))
    
    var bounding = BoundingBox()
    
    for attribute in patch.attributes {
        let buffer_view = world.buffer_view_list.get(attribute.view)!
        let actual_stride = max(attribute.stride, format_to_stride(format_str: attribute.format))
        
        let slice = buffer_view.get_slice(offset: attribute.offset)
        
        switch attribute.semantic {
        case "POSITION":
            let pos = realize_vec3(slice, .V3, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
            for p_i in 0 ..< pos.count {
                let p = pos[p_i]
                verts[p_i].position = MTLPackedFloat3Make(p.x, p.y, p.z)
                bounding = bounding.union(p)
            }
        case "NORMAL":
            let nors = realize_vec3(slice, .V3, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
            for p_i in 0 ..< nors.count {
                let n = nors[p_i]
                verts[p_i].normal = MTLPackedFloat3Make(n.x, n.y, n.z)
            }
        case "TEXTURE":
            switch attribute.format {
            case "VEC2":
                let ts = realize_tex_vec2(slice, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
                for p_i in 0 ..< ts.count {
                    let n = ts[p_i]
                    verts[p_i].uv = (n.x, n.y)
                }
            case "U16VEC2":
                let ts = realize_tex_u16vec2(slice, vcount: Int(patch.vertex_count), stride: Int(actual_stride))
                for p_i in 0 ..< ts.count {
                    let n = SIMD2<Float>(ts[p_i]) / Float(UInt16.max)
                    verts[p_i].uv = (n.x, n.y)
                }
            default:
                continue
            }
        default:
            continue
        }
    }

    
    guard let index_info = patch.indices else {
        return nil
    }
    
    let index_buff_view = world.buffer_view_list.get(index_info.view)!
    let index_bytes = index_buff_view.get_slice(offset: index_info.offset)
    
    let index = realize_index_u16(index_bytes, index_info)
    
    return CPUGlyphDescription(vertex: verts, index: index, bounding_box: bounding)
}

func realize_index_u16(_ bytes: Data, _ idx: GeomIndex) -> [UInt16] {
    if idx.stride != 0 {
        fatalError("Unable to handle strided index buffers")
    }
    
    
    return bytes.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> [UInt16] in
        
        switch idx.format {
        case "U8":
            let arr = pointer.bindMemory(to: UInt8.self)
            return Array<UInt8>(arr).map { UInt16($0) }
            
        case "U16":
            let arr = pointer.bindMemory(to: UInt16.self)
            return Array<UInt16>(arr)

        case "U32":
            let arr = pointer.bindMemory(to: UInt32.self)
            return Array<UInt32>(arr).map { UInt16($0) }
            
        default:
            fatalError("unknown index format")
        }
    }
}

func make_model_entity(scale : Float = 1.0, _ f : ()-> ([SIMD3<Float>], [SIMD3<Float>], [UInt16], BoundingBox)) -> ModelEntity {
    
    let (pos, nors, index, _) = f();
    
    let positions = pos.map {
        p in
        p * scale
    }
    
    let indicies = index.map { p in
        UInt32(p)
    };
    
    var description = MeshDescriptor()
    description.positions = MeshBuffers.Positions(positions)
    description.normals = MeshBuffers.Normals(nors)
    description.primitives = .triangles(indicies)
    
    var tri_mat = PhysicallyBasedMaterial()
    tri_mat.baseColor = PhysicallyBasedMaterial.BaseColor.init(tint: .opaqueSeparator)
    tri_mat.clearcoat = PhysicallyBasedMaterial.Clearcoat(floatLiteral: 1.0)
    tri_mat.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: 0.0)
    tri_mat.metallic  = PhysicallyBasedMaterial.Metallic(floatLiteral: 1.0)
    
    return ModelEntity(mesh: try! .generate(from: [description]), materials: [tri_mat])
}

private func determine_low_level_semantic(attribute: GeomAttrib) -> LowLevelMesh.VertexSemantic? {
    switch attribute.semantic {
    case "POSITION":
        return LowLevelMesh.VertexSemantic.position;
    case "NORMAL":
        return LowLevelMesh.VertexSemantic.normal;
    case "TEXTURE":
        let lookup = [
            LowLevelMesh.VertexSemantic.uv0,
            LowLevelMesh.VertexSemantic.uv1,
            LowLevelMesh.VertexSemantic.uv2,
            LowLevelMesh.VertexSemantic.uv3,
            LowLevelMesh.VertexSemantic.uv4,
        ]
        return lookup[Int(attribute.channel)]
    case "TANGENT":
        return LowLevelMesh.VertexSemantic.tangent
    default:
        return nil
    }
    
}

private func determine_low_level_format(attribute: GeomAttrib) -> MTLVertexFormat? {
    // only looking for valid formats for each type
    
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
            return nil
        }
    default:
        return nil
    }
    return nil
}

func bounding_box<T: Collection>(of points: T, position_extractor: (T.Element) -> SIMD3<Float>) -> BoundingBox? {
    guard let first_point = points.first else {
        return nil
    }
    
    let extract_first_point = position_extractor(first_point)
    
    var min_point = extract_first_point
    var max_point = extract_first_point
    
    for element in points {
        let point = position_extractor(element)
        min_point = min(min_point, point)
        max_point = max(max_point, point)
    }
    
    return BoundingBox(min: min_point, max: max_point)
}

@MainActor
func determine_bounding_box(attribute: GeomAttrib,
                            vertex_count: Int,
                            world: NoodlesWorld) -> BoundingBox {
    
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
    
    let buffer_view = world.buffer_view_list.get(attribute.view)!
    
    let data = buffer_view.get_slice(offset: attribute.offset);
    
    var min_bb = SIMD3<Float>(repeating: Float32.greatestFiniteMagnitude)
    var max_bb = SIMD3<Float>(repeating: -Float32.greatestFiniteMagnitude)
    
    let actual_stride = max(attribute.stride, 3*4)
    
    data.withUnsafeBytes { ptr in
        
        for p_i in 0 ..< vertex_count {
            let delta = Int(actual_stride) * p_i
            
            let l_bb = SIMD3<Float>(
                x: ptr.loadUnaligned(fromByteOffset: delta, as: Float32.self),
                y: ptr.loadUnaligned(fromByteOffset: delta + 4, as: Float32.self),
                z: ptr.loadUnaligned(fromByteOffset: delta + 8, as: Float32.self)
            )
            
            min_bb = min(min_bb, l_bb)
            max_bb = max(max_bb, l_bb)
        }
    }
    
    return BoundingBox(min: min_bb, max: max_bb)
}

private func determine_index_type(patch: GeomPatch) -> MTLPrimitiveType? {
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
        return nil
    }
}

private func format_to_stride(format_str: String) -> Int64 {
    switch format_str {
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
        return 1
    }
}

@MainActor
func patch_to_low_level_mesh(patch: GeomPatch,
                             world: NoodlesWorld) -> LowLevelMesh? {
    //print("Patch to low-level mesh")
    // these have format, layout index, offset from start of vertex data, and semantic
    var ll_attribs = [LowLevelMesh.Attribute]()
    
    // these have the buffer index, an offset to the first byte in this buffer, and a stride
    var ll_layouts = [LowLevelMesh.Layout]()
    
    // we need to pack all buffer references into the layout list
    
    struct LayoutPack : Hashable {
        let view_id : NooID
        let buffer_stride : Int64
    }
    
    var layout_mapping = [LayoutPack : Int]();
    
    var position_bb: BoundingBox?;
    
    for attribute in patch.attributes {
        //let buffer_view = world.buffer_view_list.get(attribute.view)!
        let actual_stride = max(attribute.stride, format_to_stride(format_str: attribute.format))
        //print("attribute");
        //dump(attribute)
        //dump(actual_stride)
        //dump(buffer_view)
        //let buffer = info.buffer_cache[buffer_view.source_buffer.slot]!
        
        // - attribute.view    this is essentially which buffer we are using
        // - attribute.offset  this is the offset to the buffer
        // - attribute.stride  this is the offset between attributes info
        
        //
        let key = LayoutPack(view_id: attribute.view,
                             buffer_stride: actual_stride);
        
        guard let ll_semantic = determine_low_level_semantic(attribute: attribute) else {
            continue;
        }
        
        guard let ll_format = determine_low_level_format(attribute: attribute) else {
            continue;
        }
        
        if ll_semantic == .position {
            position_bb = determine_bounding_box(attribute: attribute, vertex_count: Int(patch.vertex_count), world: world)
        }
        
        print("SEMANTICS \(ll_semantic) \(ll_format)")
        
        let layout_index = {
            if let layout_index = layout_mapping[key] {
                return layout_index
            } else {
                let layout_index = ll_layouts.count
                layout_mapping[key] = layout_index
                ll_layouts.append(LowLevelMesh.Layout(bufferIndex: layout_index,  // is this correct?
                                                      bufferOffset: 0,
                                                      bufferStride: Int(key.buffer_stride)))
                //print("ADDING LAYOUT \(key) at index \(layout_index)")
                return layout_index
            }
        }()
        
        ll_attribs.append(LowLevelMesh.Attribute(semantic: ll_semantic, format: ll_format, layoutIndex: layout_index, offset: Int(attribute.offset)))
        
    }
    
    // if we dont have a bounding box, we never had a position attrib
    
    guard let resolved_bb = position_bb else {
        print("Missing position semantic!")
        return nil
    }
    
    ll_layouts.reserveCapacity(layout_mapping.count)
    
    let format = patch.indices?.format ?? "U32"
    var index_type : MTLIndexType
    
    switch format {
    case "U16":
        index_type = .uint16
    case "U32":
        index_type = .uint32
    default:
        print("Unsupported index type")
        return nil
    }
    
    
    let meshDescriptor = LowLevelMesh.Descriptor(vertexCapacity: Int(patch.vertex_count),
                                                 vertexAttributes: ll_attribs,
                                                 vertexLayouts: ll_layouts,
                                                 indexCapacity: Int(patch.indices?.count ?? 0),
                                                 indexType: index_type)
    
    let lowLevelMesh : LowLevelMesh;
    
    do {
        // this might need to be on the main thread?
        lowLevelMesh = try LowLevelMesh(descriptor: meshDescriptor)
    } catch {
        print("Explosion in mesh generation \(error)")
        return nil
    }
    
    dump(lowLevelMesh)
    
    // now execute uploads
    
    for (k,v) in layout_mapping {
        let buffer_view = world.buffer_view_list.get(k.view_id)!
        
        let slice = buffer_view.get_slice(offset: 0)
        
        lowLevelMesh.replaceUnsafeMutableBytes(bufferIndex: v, { ptr in
            print("Uploading mesh data \(ptr.count)")
            let res = slice.copyBytes(to: ptr)
            print("Uploaded \(res)")
        })
    }
    
    if let index_info = patch.indices {
        dump(index_info)
        
        let buffer_view = world.buffer_view_list.get(index_info.view)!
        
        let bytes = buffer_view.get_slice(offset: index_info.offset)
        
        lowLevelMesh.replaceUnsafeMutableIndices { ptr in
            print("Uploading index data \(ptr.count)")
            let res = bytes.copyBytes(to: ptr)
            print("Uploaded \(res)")
        }
        
        guard let index_type = determine_index_type(patch: patch) else {
            print("Unable to determine index type!")
            return nil
        }
        
        print("Installing index part \(index_type) bb: \(resolved_bb)")
        
        lowLevelMesh.parts.replaceAll([
            .init(indexOffset: 0, indexCount: Int(index_info.count), topology: index_type, materialIndex: 0, bounds: resolved_bb)
        ])
    }
    
    return lowLevelMesh
}
