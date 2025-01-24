//
//  NoodlesWorld.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 2/16/24.
//

import Foundation
import SwiftUI
import OSLog
import RealityKit
import SwiftCBOR
import Combine

// MARK: Method
class NooMethod : NoodlesComponent {
    var info: MsgMethodCreate
    
    init(msg: MsgMethodCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        world.method_list_lookup[info.name] = self
    }
    
    func destroy(world: NoodlesWorld) { 
        world.method_list_lookup.removeValue(forKey: info.name)
    }
}

// MARK: Buffer

class NooBuffer : NoodlesComponent {
    var info: MsgBufferCreate
    
    init(msg: MsgBufferCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        print("Created buffer")
    }
    
    func destroy(world: NoodlesWorld) { }
}


// MARK: BufferView

class NooBufferView : NoodlesComponent {
    var info: MsgBufferViewCreate
    
    var buffer: NooBuffer!
    
    init(msg: MsgBufferViewCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        buffer = world.buffer_list.get(info.source_buffer)!;
        print("Created buffer view")
    }
    
    func get_slice(offset: Int64) -> Data {
        return info.get_slice(data: buffer.info.bytes, view_offset: offset)
    }
    
    func get_slice(offset: Int64, length: Int64) -> Data {
        return info.get_slice(data: buffer.info.bytes, view_offset: offset, override_length: length)
    }
    
    func destroy(world: NoodlesWorld) { }
}

// MARK: Texture

class NooTexture : NoodlesComponent {
    var info : MsgTextureCreate
    
    var noo_world : NoodlesWorld!
    
    private var resources : [TextureResource.Semantic : TextureResource] = [:]
    
    init(msg: MsgTextureCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        noo_world = world
    }
    
    func get_texture_resource_for(semantic: TextureResource.Semantic) -> TextureResource? {
        
        if let resource = resources[semantic] {
            return resource
        }
        
        guard let img = noo_world.image_list.get(info.image_id) else {
            default_log.error("Image is missing!")
            return nil
        }
        
        // TODO: Update spec to help inform APIs about texture use
        do {
            let resource = try TextureResource(image: img.image, options: .init(semantic: semantic, mipmapsMode: .allocateAndGenerateAll))
            
            resources[semantic] = resource
            
            return resource
        } catch let error {
            default_log.error("Unable to create texture: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    func destroy(world: NoodlesWorld) { }
}

// MARK: Sampler

class NooSampler : NoodlesComponent {
    var info : MsgSamplerCreate
    
    init(msg: MsgSamplerCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        
    }
    
    func destroy(world: NoodlesWorld) { }
}

// MARK: Image

private func data_to_cgimage(data: Data) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceShouldCache: true,
        kCGImageSourceShouldAllowFloat: true
    ]
    
    guard let image_source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
        return nil
    }
    
    return CGImageSourceCreateImageAtIndex(image_source, 0, options as CFDictionary)
}

private func transform_image(image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    let bitsPerComponent = image.bitsPerComponent
    let bytesPerRow = image.bytesPerRow
    let colorSpace = image.colorSpace
    let bitmapInfo = image.bitmapInfo
    
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: bitsPerComponent,
        bytesPerRow: bytesPerRow,
        space: colorSpace!,
        bitmapInfo: bitmapInfo.rawValue
    ) else { return nil }
    
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1.0, y: -1.0)
    
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    return context.makeImage()
}

class NooImage : NoodlesComponent {
    var info : MsgImageCreate
    
    var image : CGImage!
    
    init(msg: MsgImageCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        let src_bytes = get_slice(world: world)
        
        //let is_jpg = src_bytes.starts(with: [0xFF, 0xD8, 0xFF])
        //let is_png = src_bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        
        image = transform_image(image: data_to_cgimage(data: src_bytes)!)
        
        print("Creating image: \(image.width)x\(image.height)");
    }
    
    func get_slice(world: NoodlesWorld) -> Data {
        if let d = info.saved_bytes {
            return d
        }
        
        if let v_id = info.buffer_source {
            if let v = world.buffer_view_list.get(v_id) {
                return v.get_slice(offset: 0)
            }
        }
        
        return Data()
    }
    
    func destroy(world: NoodlesWorld) { }
}

private func resolve_texwrap(_ wrap_string: String) -> MTLSamplerMinMagFilter {
    if wrap_string == "NEAREST" {
        return .nearest
    }
    return .linear
}

// MARK: Material

@MainActor
private func resolve_texture(world: NoodlesWorld, semantic: TextureResource.Semantic, ref: TexRef) -> MaterialParameters.Texture? {
    guard let tex_info = world.texture_list.get(ref.texture) else {
        return nil
    }
    
    // can add sampler in here
    guard let resource = tex_info.get_texture_resource_for(semantic: semantic) else {
        return nil
    }
    
    var ret = MaterialParameters.Texture(resource);
    
    ret.swizzle = MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .alpha)
    
    if let sampler_id = tex_info.info.sampler_id {
        if let sampler = world.sampler_list.get(sampler_id) {

            let desc = MTLSamplerDescriptor()
            desc.minFilter = resolve_texwrap(sampler.info.min_filter)
            desc.magFilter = resolve_texwrap(sampler.info.mag_filter)
            
            ret.sampler = MaterialParameters.Texture.Sampler(desc)
        }
    }
    
    
    
    return ret;
}

class NooMaterial : NoodlesComponent {
    var info: MsgMaterialCreate
    
    var mat : (any RealityKit.Material)!
    
    init(msg: MsgMaterialCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        print("Creating NooMaterial")
        
        var tri_mat = PhysicallyBasedMaterial()
        
        tri_mat.baseColor = PhysicallyBasedMaterial.BaseColor.init(tint: info.pbr_info.base_color)
    
        var alpha : CGFloat = 1.0
        
        info.pbr_info.base_color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        
        if let x = info.pbr_info.base_color_texture {
            if let tex_info = resolve_texture(world: world, semantic: .color, ref: x) {
                tri_mat.baseColor.texture = tex_info
                
            } else {
                print("Missing texture!")
            }
        }
        
        if let x = info.normal_texture {
            if let tex_info = resolve_texture(world: world, semantic: .normal, ref: x) {
                tri_mat.normal = PhysicallyBasedMaterial.Normal(texture: tex_info);
                
            } else {
                print("Missing texture!")
            }
        }
        
        tri_mat.roughness = PhysicallyBasedMaterial.Roughness(floatLiteral: info.pbr_info.roughness)
        tri_mat.metallic = PhysicallyBasedMaterial.Metallic(floatLiteral: info.pbr_info.metallic)
        
        if info.use_alpha {
            tri_mat.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
        }
        
        mat = tri_mat
        
        print("Created material")
    }
    
    func destroy(world: NoodlesWorld) { }
}

// MARK: Geometry

@MainActor
class NooGeometry : NoodlesComponent {
    var info: MsgGeometryCreate
    
    var descriptors   : [LowLevelMesh] = []
    var mesh_materials: [any RealityKit.Material] = []
    
    var pending_mesh_resources: [MeshResource] = []
    
    var pending_bounding_box: BoundingBox?
    
    init(msg: MsgGeometryCreate) {
        info = msg
    }
    
    func get_mesh_resources() -> [MeshResource] {
        //print("asking for mesh resources")
        
        // backing out async stuff due to race
        if !pending_mesh_resources.isEmpty {
            //print("early return")
            return pending_mesh_resources
        }
        
        for d in descriptors {
            let res = try! MeshResource(from: d)
            self.pending_mesh_resources.append( res )
        }
        
        print("Build \(pending_mesh_resources.count) resources for mesh")
        
        return pending_mesh_resources
    }
    
    func get_bounding_box() -> BoundingBox {
        //print("get bounding box")
        
        if let bb = self.pending_bounding_box {
            //print("early return")
            return bb
        }
        var bounding_box = BoundingBox()
        let resources = get_mesh_resources()
        for res in resources {
            bounding_box = res.bounds.union(bounding_box)
        }
        
        pending_bounding_box = bounding_box
        
        //print("built")
        
        return bounding_box
    }
    
    func create(world: NoodlesWorld) {
        for patch in info.patches {
            add_patch(patch, world)
        }
        
        print("Created geometry")
    }
    
    func add_patch(_ patch: GeomPatch, _ world: NoodlesWorld) {
        let ll = patch_to_low_level_mesh(patch: patch, world: world)!;
        
        self.descriptors.append(ll)
          
        if let mat = world.material_list.get(patch.material) {
            mesh_materials.append( mat.mat )
        } else {
            var tri_mat = PhysicallyBasedMaterial()
            tri_mat.baseColor = PhysicallyBasedMaterial.BaseColor.init(tint: .white)
            mesh_materials.append( tri_mat )
        }
    }
    
    func destroy(world: NoodlesWorld) { }
}

// MARK: Entity

class NEntity : Entity, HasCollision {
    
}

@MainActor
struct SpecialAbilities {
    var can_move = false
    var can_scale = false
    var can_rotate = false
    
    var can_probe = false
    
    var can_select = false
    
    var can_activate = false
    
    init() {
        
    }
    
    init(_ list: [NooMethod]) {
        let set = Set(list.map{ $0.info.name })
        
        can_activate = set.contains(CommonStrings.activate)
        
        can_move = set.contains(CommonStrings.set_position)
        can_scale = set.contains(CommonStrings.set_scale)
        can_rotate = set.contains(CommonStrings.set_rotation)
        
        can_select = set.contains(CommonStrings.select_region)
        
        can_probe = set.contains(CommonStrings.probe_at)
    }
}

struct NooEntityRenderPrep {
    var geometry: NooGeometry
    var instance_view: NooBufferView?
}

class NooEntity : NoodlesComponent {
    var last_info: MsgEntityCreate
    
    var entity: NEntity
    
    var sub_entities: [Entity] = []
    
    var methods: [NooMethod] = []
    var abilities = SpecialAbilities()
    
    var instance: GlyphInstances?
    
    var physics: [NooPhysics] = []
    var physics_debug: Entity?
    
    init(msg: MsgEntityCreate) {
        last_info = msg
        entity = NEntity()
    }
    
    @MainActor
    func common(world: NoodlesWorld, msg: MsgEntityCreate) {
        //dump(msg)
        
        if let n = msg.name {
            entity.name = n
        }
        
        // setting parent?
        if let parent = msg.parent {
            // a set or unset?
            if parent.is_valid() {
                let parent_ent = world.entity_list.get(parent)!
                parent_ent.entity.addChild(entity)
            } else {
                world.root_entity.addChild(entity)
            }
        }
        
        if let tf = msg.tf {
            switch tf {
            case .matrix(let mat):
                handle_new_tf(world, transform: mat)
                break;
            case .qr_code(let identifier):
                //
                break;
            case .geo_coordinates(let location):
                //
                break;
            }
            
        }
        
        if let _ = msg.null_rep {
            unset_representation(world);
        } else if let g = msg.rep {
            //print("adding mesh rep")
            // we need to obtain references to stuff in world to make sure we dont get clobbered
            // while doing work in another task
            let prep = NooEntityRenderPrep(
                geometry: world.geometry_list.get(g.mesh)!,
                instance_view: g.instances.map { world.buffer_view_list.get($0.view)! }
            )
            
            let new_subs = self.build_sub_render_representation(g, prep, world);
            
            self.unset_representation(world);
            
            for sub in new_subs {
                self.add_sub(sub)
            }
            
        }
        
        if let p = msg.physics {
            print("Updating physics!")
            if let q = physics_debug {
                q.removeFromParent()
                entity.removeChild(q)
            }
            
            let fp = p.first!
            
            let physics = world.physics_list.get(fp)!
            
            let advector_state = physics.advector_state!

            let physics_context = ParticleContext(
                advect_multiplier: 10.0,
                time_delta: 1/60.0,
                max_lifetime: 10.0,
                bb_min: float_to_packed(advector_state.bb.min),
                bb_max: float_to_packed(advector_state.bb.max),
                vfield_dim: pack_cast(advector_state.velocity.dims),
                number_particles: UInt32(advector_state.num_particles),
                spawn_range_start: 0,
                spawn_range_count: 0,
                spawn_at: MTLPackedFloat3Make(0.0, 0.0, 0.0),
                spawn_at_radius: 0.25
            )
            
            let component = make_advection_component(context: physics_context)
            
            component.velocity_vector_field.contents().copyMemory(
                from: advector_state.velocity.array,
                byteCount: component.velocity_vector_field.length
            )
            
            entity.components.set(component)
            
            print("Adding Hack advector physics")
            
            let advector_ent = Entity()
            
            let resource = try! MeshResource(from: component.glyph_system.low_level_mesh)

            let model_component = ModelComponent(mesh: resource, materials: [PhysicallyBasedMaterial()])

            advector_ent.components.set(model_component)
            
            //advector_ent.position = advector_state.bb.center
            advector_ent.position = .zero
            
            advector_ent.components.set(AdvectionSpawnComponent())
            
            entity.addChild(advector_ent)
        }
        
        if let mthds = msg.methods_list {
            methods = mthds.compactMap {
                world.methods_list.get($0)
            }
            
            
            abilities = SpecialAbilities(methods)
            
            if abilities.can_move || abilities.can_rotate || abilities.can_scale {
                install_gesture_control(world)
                
                if world.set_item_input_cached {
                    set_input_enabled(enabled: true)
                }
                
            } else {
                if entity.components.has(GestureComponent.self) {
                    entity.components.remove(GestureComponent.self);
                }
            }
        }
        
        if let visibility = msg.visible {
            //dump(msg)
            entity.isEnabled = visibility
        }
        
        if let billboard = msg.billboard {
            if (billboard) {
                entity.components.set(BillboardComponent())
            } else {
                entity.components.remove(BillboardComponent.self)
            }
        }
    }
    
    func handle_new_tf(_ world: NoodlesWorld, transform: simd_float4x4) {
        // If the user is dragging and a transform update comes in, we can delay it
        // until they are done
        if entity.gestureComponent != nil {
            let shared = EntityGestureState.shared
            if shared.targetedEntity == entity {
                if shared.isDragging || shared.isRotating || shared.isScaling {
                    print("Delaying transform update for entity!")
                    entity.components[GestureSupportComponent.self]?.pending_transform = transform
                    return;
                }
            }
        }
        
        entity.move(to: transform, relativeTo: entity.parent, duration: 0.1)
    }
    
    func install_gesture_control(_ world: NoodlesWorld) {
        print("Installing gesture controls...")
        
        // this gets called AFTER we do a render rep
        // if there is NO render rep, nothing will work
        
        let gesture = GestureComponent(canDrag: abilities.can_move,
                                       pivotOnDrag: false,
                                       canScale: abilities.can_scale,
                                       canRotate: abilities.can_rotate
        )
        
        let support = GestureSupportComponent(
            world: world, noo_id: last_info.id
        )
        entity.components.set(gesture)
        entity.components.set(support)
        entity.components.set(HoverEffectComponent(
            .highlight(.init(color: .systemBlue, strength: 5.0))
        ))
        
        entity.components.set(InputTargetComponent())
    }
    
    @MainActor
    func create(world: NoodlesWorld) {
        //world.scene.add(entity)
        world.root_entity.addChild(entity)

        common(world: world, msg: last_info)
        
        //print("Created entity")
    }
    
    func unset_representation(_ world: NoodlesWorld) {
        clear_subs(world)
    }
    
    func add_sub(_ ent: Entity) {
        sub_entities.append(ent)
        
        entity.addChild(ent)
    }
    
    @MainActor
    func build_instance_representation(_ src: InstanceSource,
                                       _ prep: NooEntityRenderPrep,
                                       _ world: NoodlesWorld
    ) -> ([Entity], BoundingBox)? {
        
        guard let v = prep.instance_view else {
            print("Warning: missing instance view")
            return nil
        }
        
        let instance_data = v.get_slice(offset: 0)
        let instance_count = instance_data.count / MemoryLayout<float4x4>.stride
        // just in case things arent quite rounded off
        let instances_byte_count = Int(instance_count) * MemoryLayout<float4x4>.stride
        
        print("Building \(instance_count) instances")
        
        guard instance_count > 0 else {
            return nil
        }
        
        let instance_buffer = ComputeContext.shared.device.makeBuffer(length: instances_byte_count, options: .storageModeShared)!
        
        instance_data.withUnsafeBytes {
            (pointer: UnsafeRawBufferPointer) -> () in
            instance_buffer.contents().copyMemory(from: pointer.baseAddress!, byteCount: instances_byte_count)
        }
        
        guard let glyph = patch_to_glyph(prep.geometry.info.patches.first, world: world) else {
            return nil
        }
        
        //        if instance_count == 1 {
        //            dump(glyph);
        //        }
        
        let instances = GlyphInstances(instance_count: UInt32(instance_count), description: GPUGlyphDescription(from: glyph))
        
        var bounding_box : BoundingBox
        
        if let bb = src.bb {
            bounding_box = BoundingBox(min: bb.min, max: bb.max)
        } else {
            default_log.warning("Unknown bounding box, having to compute by hand...")
            
            bounding_box = instance_data.withUnsafeBytes {
                (pointer: UnsafeRawBufferPointer) -> BoundingBox in
                let bind = pointer.bindMemory(to: simd_float4x4.self)
                
                var new_bb = BoundingBox();
                
                for i in bind {
                    new_bb.formUnion(SIMD3<Float>(i[0].x, i[0].y, i[0].z))
                }
                
                return new_bb
            }
            
            print("Computed to \(bounding_box)")
        }
        
        {
            let sesson = ComputeSession()!
            
            instances.update(instance_buffer: instance_buffer, bounds: bounding_box, session: sesson)
        }()
        
        let mat = prep.geometry.mesh_materials[0]
        
        let res = try! MeshResource(from: instances.low_level_mesh)
        let model = ModelComponent(mesh: res, materials: [mat])
        
        let ent = Entity()
        ent.name = "Instances"
        ent.components.set(model)
        
        print("Done with instances")
        
        return ([ent], bounding_box)
    }
    
    @MainActor
    func build_sub_render_representation(_ rep: RenderRep, _ prep: NooEntityRenderPrep, _ world: NoodlesWorld) -> [Entity] {
        var subs = [Entity]();
        
        let geom = prep.geometry
        
        if let instances = rep.instances {
            print("Noodles ent has instances, building")
            
            guard let (new_subs, _) = build_instance_representation(instances, prep, world) else {
                return []
            }
            
            subs = new_subs
            
        } else {
            for (mat, mesh) in zip(geom.mesh_materials, geom.get_mesh_resources()) {
                let new_entity = ModelEntity(mesh: mesh, materials: [mat])
                subs.append(new_entity)
            }
        }

        
        
        return subs
    }
    
    @MainActor
    func set_input_enabled(enabled: Bool) {
        guard var c = entity.components[InputTargetComponent.self] else {
            return
        }
        
        c.isEnabled = enabled
        
        if enabled {
            var bb = BoundingBox()
            for sub_entity in sub_entities {
                if let geom = sub_entity.components[ModelComponent.self] {
                    bb = bb.union(geom.mesh.bounds)
                }
            }
            
            let cc = CollisionComponent(shapes: [ShapeResource.generateBox(size: bb.extents).offsetBy(translation: bb.center)]);
            
            entity.components.set(cc);
        } else {
            entity.components.remove(CollisionComponent.self)
        }
    }
    
    @MainActor
    func update(world: NoodlesWorld, _ update: MsgEntityCreate) {
        common(world: world, msg: update)
        last_info = update
    }
    
    private func clear_subs(_ world: NoodlesWorld) {
        //print("Clearing subs!")
        for sub_entity in sub_entities {
            entity.removeChild(sub_entity)
        }
        sub_entities.removeAll(keepingCapacity: true)
    }
    
    func destroy(world: NoodlesWorld) {
        clear_subs(world)
        entity.removeFromParent()
    }
    
}

enum VAttribFormat {
    case V2
    case V3
}

extension VAttribFormat {
    func byte_size() -> Int {
        switch self {
        case .V2:
            return 2 * 4
        case .V3:
            return 3 * 4
        }
    }
}

func realize_tex_u16vec2(_ data: Data, vcount: Int, stride: Int) -> [SIMD2<UInt16>] {
    let true_stride = max(stride, 2*2);
    
    return data.withUnsafeBytes {
        (pointer: UnsafeRawBufferPointer) -> [SIMD2<UInt16>] in
        
        var ret : [SIMD2<UInt16>] = []
        
        ret.reserveCapacity(vcount)
        
        for vertex_i in 0 ..< vcount {
            let place = vertex_i * true_stride
            var item = pointer.loadUnaligned(fromByteOffset: place, as: SIMD2<UInt16>.self)
            item.y = 65535 - item.y;
            ret.append( item )
        }
        
        return ret
    }
}


func realize_tex_vec2(_ data: Data, vcount: Int, stride: Int) -> [SIMD2<Float>] {
    let true_stride = max(stride, 2*4);
    
    return data.withUnsafeBytes {
        (pointer: UnsafeRawBufferPointer) -> [SIMD2<Float>] in
        
        var ret : [SIMD2<Float>] = []
        
        ret.reserveCapacity(vcount)
        
        for vertex_i in 0 ..< vcount {
            let place = vertex_i * true_stride
            var p = pointer.loadUnaligned(fromByteOffset: place, as: SIMD2<Float>.self)
            p.y = 1.0 - p.y;
            ret.append( p )
        }
        
        return ret
    }
}

func realize_vec3(_ data: Data, _ fmt: VAttribFormat, vcount: Int, stride: Int) -> [SIMD3<Float>] {
    if fmt != VAttribFormat.V3 {
        print("No conversions for vformats yet!");
        return []
    }
    
    let true_stride = max(stride, fmt.byte_size())
    
    return data.withUnsafeBytes {
        (pointer: UnsafeRawBufferPointer) -> [SIMD3<Float>] in
        
        var ret : [SIMD3<Float>] = []
        
        ret.reserveCapacity(vcount)
        
        for vertex_i in 0 ..< vcount {
            let place = vertex_i * true_stride
            //print("CONV", place, data.count, data.startIndex, data.endIndex, data[data.count - 1])
            //print("CONV2", MemoryLayout<SIMD3<Float>>.size, MemoryLayout<SIMD3<Float>>.stride)
            //padding in the simd causes joy!
            let x = pointer.loadUnaligned(fromByteOffset: place + 0, as: Float32.self)
            let y = pointer.loadUnaligned(fromByteOffset: place + 4, as: Float32.self)
            let z = pointer.loadUnaligned(fromByteOffset: place + 8, as: Float32.self)
            ret.append(.init(x, y, z))
            //ret.append( pointer.loadUnaligned(fromByteOffset: place, as: SIMD3<Float>.self) )
        }
        
        return ret
    }
}

func realize_mat4(_ data: Data) -> [simd_float4x4] {
    let mat_count = data.count / (4*4*4);
    
    return data.withUnsafeBytes {
        (pointer: UnsafeRawBufferPointer) -> [simd_float4x4] in
        
        var ret : [simd_float4x4] = []
        
        ret.reserveCapacity(mat_count)
        
        for mat_i in 0 ..< mat_count {
            let place = mat_i * (4*4*4)
            ret.append( pointer.loadUnaligned(fromByteOffset: place, as: simd_float4x4.self) )
        }
        
        return ret
    }
}

func vec4_to_vec3(_ v : simd_float4) -> simd_float3 {
    return simd_float3(v.x, v.y, v.z)
}

func matrix_multiply(_ mat: simd_float4x4, _ v : simd_float3) -> simd_float3 {
    let v4 = simd_float4(v, 1.0)
    let ret = matrix_multiply(mat, v4)
    return vec4_to_vec3(ret) / ret.w
}

// MARK: Advection

struct AdvectionID : Equatable {
    let line_id: UInt32
    let offset : UInt32
}

@MainActor
class NooAdvectorState {
    var lines: [NooFlowLine]
    
    var bb = BoundingBox()
    
    var num_particles = 1000
    
    var velocity : Grid3D<simd_float3>
    
    init(sf: StreamFlowInfo, world: NoodlesWorld) {
        print("Creating debug flow geom")
        
        guard let buffer_view = world.buffer_view_list.get(sf.data) else {
            print("Missing buffer view")
            lines = []
            velocity = Grid3D(1, 1, 1, .zero)
            return
        }
        
        // since we cant do offsets of offsets here...
        let data = buffer_view.get_slice(offset: Int64(sf.offset))
        
        var cursor = 0
        
        // extract topology
        let tetra_count = data.withUnsafeBytes {
            (pointer: UnsafeRawBufferPointer) -> UInt32 in
            return pointer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
        } / 4
        
        print("Tetra count is \(tetra_count)")
        
        cursor += 4
        
        let tetra_indicies = data.withUnsafeBytes {
            var ret = [TetrahedraIndex]()
            ret.reserveCapacity(Int(tetra_count))
            
            for _ in 0 ..< tetra_count {
                ret.append(TetrahedraIndex(indicies: .init(
                    x: $0.loadUnaligned(fromByteOffset: cursor + 0, as: UInt32.self),
                    y: $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self),
                    z: $0.loadUnaligned(fromByteOffset: cursor + 8, as: UInt32.self),
                    w: $0.loadUnaligned(fromByteOffset: cursor + 12, as: UInt32.self))))
                cursor += 16
            }
            
            return ret
        }
        
        print("Looking for \(sf.header.line_count) lines")
        
        lines = []
        
        // now lets read lines, and find the bounds of this system
        
        var min_b = simd_float3(repeating: 100000000.0) // ha ha
        var max_b = simd_float3(repeating: -100000000.0) // ha ha haaaa
        
        var all_positions = [simd_float3]()
        var all_vectors = [simd_float3]()
        
        for _ in 0 ..< sf.header.line_count {
            let (new_line, new_cursor) = extract_line(data, base_offset: cursor, acount: sf.header.attributes.count)
            
            all_positions.append(contentsOf: new_line.positions)
            
            for pos_i in 0 ..< new_line.positions.count - 1 {
                let a = new_line.positions[pos_i]
                let b = new_line.positions[pos_i + 1]
                
                all_vectors.append(b-a);
            }
            // and we do the last one here as a duplicate as there is no next vector to steal
            all_vectors.append(all_vectors.last!);
            
            for p in new_line.positions {
                min_b = simd_min(min_b, p)
                max_b = simd_max(max_b, p)
            }
            
            lines.append(new_line)
            cursor = new_cursor
        }
        
        self.bb = BoundingBox(min: min_b, max: max_b)
        
        assert(all_vectors.count == all_positions.count)
        
        print("Added \(lines.count) lines")
        
        // we have bounds, and we have tetra, and we have lines.
        
        // raster the tetra?
        
        let raster = TetraGridRasterizer(grid_bounds: BoundingBox(min: min_b, max: max_b), resolution: 10, positions: all_positions, indicies: tetra_indicies)
        
        
        self.velocity = raster.interpolate_data(indicies: tetra_indicies, positions: all_positions, data: all_vectors, repeating: .zero)
        
        print("Rasterized \(self.velocity.dims)")
    }
}

class NooPhysics : NoodlesComponent{
    var info: MsgPhysicsCreate
    
    var advector_state : NooAdvectorState?
    
    
    init(msg: MsgPhysicsCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) { 
        guard let sf = info.stream_flow else {
            print("Missing stream flow")
            return
        }
        
        advector_state = NooAdvectorState(sf: sf, world: world)
    }
    
    func destroy(world: NoodlesWorld) { }
}

struct NooFlowAttr {
    var data: [Float32]
}
struct NooFlowLine {
    var sample_count: UInt32
    
    var positions: [SIMD3<Float>]
    
    var attribs: [NooFlowAttr]
}

func extract_line(_ data: Data, base_offset: Int, acount: Int) -> (NooFlowLine, Int) {
    // print("EX LINE \(base_offset) \(acount)")
    
    var cursor = base_offset
    
    let sample_count = data.withUnsafeBytes {
        (pointer: UnsafeRawBufferPointer) -> UInt32 in
        return pointer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
    }
    
    // print("SAMPLE COUNT \(sample_count)")
    
    cursor += 4
    
    let positions = data.withUnsafeBytes {
        (pointer: UnsafeRawBufferPointer) -> [SIMD3<Float>] in
        
        var ret : [SIMD3<Float>] = []
        
        ret.reserveCapacity(Int(sample_count))
        
        for _ in 0 ..< sample_count {
            //padding in the simd causes joy!
            let x = pointer.loadUnaligned(fromByteOffset: cursor + 0, as: Float32.self)
            let y = pointer.loadUnaligned(fromByteOffset: cursor + 4, as: Float32.self)
            let z = pointer.loadUnaligned(fromByteOffset: cursor + 8, as: Float32.self)
            ret.append(.init(x, y, z))
            
            cursor += 3 * 4
        }
        
        return ret
    }
    
    // print("P_END \(cursor)")
    
    var new_line = NooFlowLine(sample_count: sample_count, positions: positions, attribs: [])
    
    for _ in 0 ..< acount {
        let attrib_data = data.withUnsafeBytes {
            (pointer: UnsafeRawBufferPointer) -> [Float32] in
            
            var ret : [Float32] = []
            
            ret.reserveCapacity(Int(sample_count))
            
            for _ in 0 ..< sample_count {
                let x = pointer.loadUnaligned(fromByteOffset: cursor , as: Float32.self)
                ret.append(x)
                
                cursor += 4
            }
            
            return ret
        }
        
        new_line.attribs.append(NooFlowAttr(data: attrib_data))
    }
    
    // print("A_END \(cursor)")
    
    return (new_line, cursor)
}

@MainActor
public class ComponentList<T: NoodlesComponent> {
    var list : Dictionary<UInt32, T> = [:]
    
    func set(_ id: NooID, _ val : T, _ world: NoodlesWorld) {
        assert(id.is_valid())
        list[id.slot] = val
        val.create(world: world)
    }
    
    func get(_ id: NooID) -> T? {
        return list[id.slot]
    }
    
    func erase(_ id: NooID, _ world: NoodlesWorld) {
        if let v = list.removeValue(forKey: id.slot) {
            v.destroy(world: world)
        }
    }
    
    func clear(_ world: NoodlesWorld) {
        for v in list.values {
            v.destroy(world: world)
        }
        list.removeAll()
    }
}

// MARK: World
@MainActor
public class NoodlesWorld {
    public weak var comm: NoodlesCommunicator?
    
    // This is the entity that we branch all our generated entities off of
    var external_root: Entity
    
    internal var methods_list = ComponentList<NooMethod>()
    internal var method_list_lookup = [String: NooMethod]()
    //public var signals_list = ComponentList<MsgSignalCreate>()
    
    internal var entity_list = ComponentList<NooEntity>()
    //public var plot_list = ComponentList<MsgPlotCreate>()
    //public var table_list = ComponentList<MsgTableCreate>()
    
    internal var material_list = ComponentList<NooMaterial>()
    
    internal var geometry_list = ComponentList<NooGeometry>()
    
    //public var light_list = ComponentList<MsgLightCreate>()
    
    internal var image_list = ComponentList<NooImage>()
    internal var texture_list = ComponentList<NooTexture>()
    internal var sampler_list = ComponentList<NooSampler>()
    //public var signal_list = ComponentList<MsgSignalCreate>()
    
    internal var buffer_view_list = ComponentList<NooBufferView>()
    internal var buffer_list = ComponentList<NooBuffer>()
    
    internal var physics_list = ComponentList<NooPhysics>()
    
    internal var attached_method_list = [NooMethod]()
    internal var visible_method_list: MethodListObservable
    
    internal var invoke_mapper = [String:(MsgMethodReply) -> ()]()
    
    var set_item_input_cached : Bool = false
    
    var root_entity : Entity
    public var root_controller: Entity
    
    //var instance_test: GlyphInstances
    
    @MainActor
    public init(_ root: Entity, _ doc_method_list: MethodListObservable, initial_offset: simd_float3 = .zero) async {
        self.visible_method_list = doc_method_list
        
        external_root = root
        
        root_controller = await make_root_handle();
        
        let bb = root_controller.visualBounds(relativeTo: root_controller.parent)
        var gesture = GestureComponent(canDrag: true, pivotOnDrag: false, canScale: true, canRotate: true)
        gesture.delegateToParent = true
        let input = InputTargetComponent()
        let coll  = CollisionComponent(shapes: [ShapeResource.generateSphere(radius: bb.boundingRadius)])
        root_controller.components.set(gesture)
        root_controller.components.set(input)
        root_controller.components.set(coll)
        root_controller.name = "Root Controller"
        root_controller.isEnabled = false
        
        root_entity = Entity()
        root_entity.name = "Root Entity"
        root_entity.transform.translation = initial_offset
        root_entity.addChild(root_controller)
        
        root.children.append(root_entity)
        
        
        //print("Creating root entity:")
        //dump(root_entity)
        
//        let gdesc = make_glyph(shape_sphere)
//        
//        instance_test = GlyphInstances(instance_count: 10, description: GPUGlyphDescription(from: gdesc))
//        
//        let test_entity = ModelEntity(mesh: try! MeshResource.init(from: instance_test.low_level_mesh),
//                                      materials: [ PhysicallyBasedMaterial() ])
//        
//        root_entity.addChild(test_entity)
    }
    
    @MainActor
    func handle_message(_ msg: FromServerMessage) {
        //dump(msg)
        switch (msg) {
            
        case .method_create(let x):
            let e = NooMethod(msg: x)
            methods_list.set(x.id, e, self)
        case .method_delete(let x):
            methods_list.erase(x.id, self)
            
        case .signal_create(_):
            break
        case .signal_delete(_):
            break
            
        case .entity_create(let x):
            let e = NooEntity(msg: x)
            entity_list.set(x.id, e, self)
        case .entity_update(let x):
            if let item = entity_list.get(x.id) {
                item.update(world: self, x);
            }
        case .entity_delete(let x):
            entity_list.erase(x.id, self)
            
        case .plot_create(_):
            break
        case .plot_update(_):
            break
        case .plot_delete(_):
            break
            
        case .buffer_create(let x):
            let e = NooBuffer(msg: x)
            buffer_list.set(x.id, e, self)
        case .buffer_delete(let x):
            buffer_list.erase(x.id, self)
            
        case .buffer_view_create(let x):
            let e = NooBufferView(msg: x)
            buffer_view_list.set(x.id, e, self)
        case .buffer_view_delete(let x):
            buffer_view_list.erase(x.id, self)
            
        case .material_create(let x):
            let e = NooMaterial(msg: x)
            material_list.set(x.id, e, self)
        case .material_update(_):
            break
        case .material_delete(let x):
            material_list.erase(x.id, self)
            
        case .image_create(let x):
            let e = NooImage(msg: x)
            image_list.set(x.id, e, self)
        case .image_delete(let x):
            image_list.erase(x.id, self)
            
        case .texture_create(let x):
            let e = NooTexture(msg: x)
            texture_list.set(x.id, e, self)
        case .texture_delete(let x):
            texture_list.erase(x.id, self)
            
        case .sampler_create(let x):
            let e = NooSampler(msg: x)
            sampler_list.set(x.id, e, self)
        case .sampler_delete(let x):
            sampler_list.erase(x.id, self)
            
        case .light_create(_):
            break
        case .light_update(_):
            break
        case .light_delete(_):
            break
            
        case .geometry_create(let x):
            let e = NooGeometry(msg: x)
            geometry_list.set(x.id, e, self)
        case .geometry_delete(let x):
            geometry_list.erase(x.id, self)
            
        case .table_create(_):
            break
        case .table_update(_):
            break
        case .table_delete(_):
            break
            
        case .document_update(let x):
            print("updating document methods and signals")
            self.attached_method_list = x.methods_list?.compactMap({f in methods_list.get(f)}) ?? []
            
            
            self.visible_method_list.reset_list( self.attached_method_list.map {
                method in
                AvailableMethod(
                    noo_id: method.info.id,
                    name: method.info.name,
                    doc: method.info.doc,
                    context_type: String()
                )
            })

        case .document_reset(_):
            break
            
        case .signal_invoke(_):
            break
            
        case .method_reply(let x):
            print("Got method reply")
            if let value = self.invoke_mapper[x.invoke_id] {
                print("Has value, execute")
                value(x)
            }
            self.invoke_mapper.removeValue(forKey: x.invoke_id)
            
        case .document_initialized(_):
            break
            
        case .physics_create(let x):
            let e = NooPhysics(msg: x)
            physics_list.set(x.id, e, self)
        case .physics_delete(let x):
            physics_list.erase(x.id, self)
        }
    }
    
    public func clear() {
        entity_list.clear(self)
        material_list.clear(self)
        geometry_list.clear(self)
        texture_list.clear(self)
        image_list.clear(self)
    }
    
    public func frame_all(target_volume : SIMD3<Float>) {
        
        // check if we need to just reset scale
        
        if root_entity.transform.scale.x != 1.0 {
            var current_tf = root_entity.transform
            
            current_tf.translation = .zero
            current_tf.scale = .one
            current_tf.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            
            root_entity.move(to: current_tf, relativeTo: root_entity.parent, duration: 2)
            return
        }
        
        let bounds = root_entity.visualBounds(recursive: true, relativeTo: root_entity.parent)
        
        print("Frame bounds \(bounds) \(bounds.center)");
        
        // ok has to be a better way to do this
        
        let target_box = target_volume
        
        let scales = target_box / (bounds.extents)
        
        print("Scales \(scales)")
        
        let new_uniform_scale = scales.min()
        
        print("Scales min \(new_uniform_scale)")
        
        var current_tf = root_entity.transform
        
        current_tf.translation = -bounds.center * new_uniform_scale
        //current_tf.translation = -bounds.center
        current_tf.scale = SIMD3<Float>(repeating: new_uniform_scale)
        
        root_entity.move(to: current_tf, relativeTo: root_entity.parent, duration: 2)
    }
    
    public func invoke_method(method: NooID,
                       context: InvokeMessageOn,
                       args: [CBOR],
                       on_done: ((MsgMethodReply) -> Void)? = nil
    ) {
        // generate id
        
        var message = InvokeMethodMessage(method: method, context: context, args: args)
        
        //dump(message)
        
        if let od = on_done {
            let id = UUID().uuidString
            
            print("New id is \(id)")
            
            message.invoke_id = id
            self.invoke_mapper[id] = od
        }
        
        comm!.send(msg: message)
    }
    
    public func invoke_method_by_name(method_name: String,
                               context: InvokeMessageOn,
                               args: [CBOR],
                               on_done: ((MsgMethodReply) -> Void)? = nil
    ) {
        guard let mthd = method_list_lookup[method_name] else { return }
        
        invoke_method(method: mthd.info.id, context: context, args: args, on_done: on_done)
    }
    
    public func set_all_entity_input(enabled: Bool) {
        print("Setting input component", enabled)
        set_item_input_cached = enabled
        for (_,v) in entity_list.list {
            v.set_input_enabled(enabled: enabled)
        }
    }
}

public struct AvailableMethod: Identifiable, Hashable {
    public var id = UUID()
    public var noo_id : NooID
    public var name : String
    public var doc : String?
    public var context: NooID?
    public var context_type: String
}

@Observable public class MethodListObservable {
    public var available_methods = [AvailableMethod]()
    public var has_step_time = false
    public var has_time_animate = false
    
    public init(available_methods: [AvailableMethod] = [AvailableMethod]()) {
        self.available_methods = available_methods
        self.has_step_time = false
        self.has_time_animate = false
    }
    
    @MainActor
    public func reset_list(_ l: [AvailableMethod]) {
        available_methods.removeAll()
        available_methods = l
        
        has_step_time = available_methods.contains(where: { $0.name == CommonStrings.step_time })
        has_time_animate = available_methods.contains(where: { $0.name == CommonStrings.step_time })
        
        dump(available_methods)
    }
    
    public func has_any_time_methods() -> Bool {
        return has_step_time || has_time_animate
    }
    
    @MainActor
    public func find_by_name(_ name: String) -> AvailableMethod? {
        return available_methods.first(where: { $0.name == name })
    }
}
