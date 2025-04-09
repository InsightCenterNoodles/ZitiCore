//
//  NoodlesWorld.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 2/16/24.
//

import Foundation
import SwiftUI
import RealityKit
import SwiftCBOR
import Combine

// MARK: Method

/// Represents a remotely-defined method callable within the NoodlesWorld runtime.
/// Registered via `MsgMethodCreate` and looked up by name for invocation.
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

/// Represents a raw data buffer, typically containing geometry, image, or simulation data.
/// Buffers are referenced by views (`NooBufferView`) for slicing and interpretation.
class NooBuffer : NoodlesComponent {
    var info: MsgBufferCreate
    
    init(msg: MsgBufferCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        print("Created buffer: \(info.id)")
    }
    
    func destroy(world: NoodlesWorld) {
        print("Deleted buffer: \(info.id)")
    }
}


// MARK: BufferView

/// Provides a view into a `NooBuffer`, allowing sliced access to portions of binary data.
/// Used for interpreting structured content such as vertex attributes or image bytes.
class NooBufferView : NoodlesComponent {
    var info: MsgBufferViewCreate
    
    var buffer: NooBuffer?
    
    init(msg: MsgBufferViewCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        print("Created buffer view: \(info.id) -> \(info.source_buffer)")
        buffer = world.buffer_list.get(info.source_buffer);
    }
    
    func get_slice(offset: Int64) -> Data? {
        guard let buffer else { return nil }
        return info.get_slice(data: buffer.info.bytes, view_offset: offset)
    }
    
    func get_slice(offset: Int64, length: Int64) -> Data? {
        guard let buffer else { return nil }
        return info.get_slice(data: buffer.info.bytes, view_offset: offset, override_length: length)
    }
    
    func destroy(world: NoodlesWorld) {
        print("Deleted buffer view: \(info.id)")
    }
}

// MARK: Texture

func generate_placeholder_image(width: Int, height: Int, color: UIColor) -> CGImage? {
    let context = CGContext(data: nil,
                                  width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!

    context.saveGState()
    context.setFillColor(gray: 0, alpha: 1.0)
    context.fill(CGRect(x: 0, y:0, width: width, height: height))

    context.restoreGState()

    return context.makeImage()
}

/// Represents a GPU texture resource sourced from an image.
/// Lazily resolves and uploads texture data on demand, including fallback placeholder logic.
class NooTexture : NoodlesComponent {
    var info : MsgTextureCreate
    
    var noo_world : NoodlesWorld!
    
    private var resources : [TextureResource.Semantic : TextureResource] = [:]
    
    static let placeholder = generate_placeholder_image(width: 32, height: 32, color: .gray)!
    
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
        
        guard let noo_image = noo_world.image_list.get(info.image_id) else {
            default_log.error("NooImage is missing!")
            return nil
        }
        
        guard let image = noo_image.image else {
            default_log.error("NooImage has no image to use!")
            return nil
        }
        
        // TODO: Update spec to help inform APIs about texture use
        do {
            
            // create a placeholder
            let resource = try TextureResource(image: NooTexture.placeholder, options: .init(semantic: semantic));
            
            resources[semantic] = resource
            
            // now kick off installation of the REAL texture
            
            Task {
                try await resource.replace(using: image, options: .init(semantic: semantic, mipmapsMode: .allocateAndGenerateAll))
            }
            
            return resource
        } catch let error {
            default_log.error("Unable to create texture: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    func destroy(world: NoodlesWorld) { }
}

// MARK: Sampler

/// Represents a sampler object used for texture filtering configuration.
/// Currently minimally implemented—can be extended with wrap/filter state.
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

/// Stores an image and its associated metadata. Converts raw buffer data into `CGImage` at runtime.
/// Supports caching, lazy loading, and diagnostic logging for missing or invalid image sources.
class NooImage : NoodlesComponent {
    var info : MsgImageCreate
    
    var image : CGImage?
    
    init(msg: MsgImageCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        guard let src_bytes = get_slice(world: world) else {
            default_log.error("Unable to get byte slice for image data \(String(describing: self.info.id))");
            return
        }
        
        if let new_image = data_to_cgimage(data: src_bytes) {
            image = new_image
            
            default_log.info("Creating image: \(new_image.width)x\(new_image.height)");
        }
    }
    
    func get_slice(world: NoodlesWorld) -> Data? {
        if let d = info.saved_bytes {
            return d
        }
        
        if let v_id = info.buffer_source {
            if let v = world.buffer_view_list.get(v_id) {
                return v.get_slice(offset: 0)
            }
        }
        
        default_log.warning("Unable to get a valid slice for an image!")
        
        return nil
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

/// Wraps a RealityKit `Material` and builds a physically-based material from provided info.
/// Supports textures, tinting, roughness/metallic properties, and alpha blending.
class NooMaterial : NoodlesComponent {
    var info: MsgMaterialCreate
    
    var mat : (any RealityKit.Material)!
    
    init(msg: MsgMaterialCreate) {
        info = msg
    }
    
    func create(world: NoodlesWorld) {
        print("Creating NooMaterial: \(info.id)")
        
        var tri_mat = PhysicallyBasedMaterial()
        
        tri_mat.textureCoordinateTransform.scale = SIMD2<Float>(1.0, -1.0)
        
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

/// Represents GPU geometry composed of one or more patches (`GeomPatch`) converted to mesh resources.
/// Caches mesh resources and bounding box computations for reuse during rendering.
@MainActor
class NooGeometry : NoodlesComponent {
    var info: MsgGeometryCreate
    
    var descriptors   : [LowLevelMesh] = []
    var mesh_materials: [any RealityKit.Material] = []
    
    var pending_mesh_resources: [MeshResource] = []
    
    var pending_bounding_box: BoundingBox?
    
    init(msg: MsgGeometryCreate) {
        info = msg
        print("Creating geometry: \(info.id)")
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
        guard let ll = patchToLowLevelMesh(patch: patch, world: world) else {
            default_log.error("Unable to build patch for geometry \(String(describing: self.info.id))")
            return
        }
        
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
/// Represents interaction capabilities available for an entity, inferred from attached methods.
/// Used to determine which gesture controls should be installed.
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

/// Helper struct used to prepare rendering data for a `NooEntity`.
/// Caches references to the associated geometry and optional instance buffer view.
struct NooEntityRenderPrep {
    var geometry: NooGeometry
    var instance_view: NooBufferView?
}

/// Represents an instanced entity in the scene graph, with optional geometry, methods, and physics.
/// Handles representation, parenting, gesture controls, and visual components dynamically.
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
    
    /// Shared logic for both creating and updating a `NooEntity`.
    /// Handles parenting, transformation, rendering, physics, gestures, and visibility.
    /// - Parameters:
    ///   - world: The current `NoodlesWorld` context.
    ///   - msg: The entity creation or update message to apply.
    @MainActor
    func common(world: NoodlesWorld, msg: MsgEntityCreate) {
        applyNameAndParentHierarchy(world, msg)
        applyTransform(world, msg)
        updateRenderRepresentation(world, msg)
        updatePhysics(world, msg)
        updateMethodsAndGestures(world, msg)
        updateVisibility(world, msg)
    }
    
    private func applyNameAndParentHierarchy(_ world: NoodlesWorld, _ msg: MsgEntityCreate) {
        if let name = msg.name {
            entity.name = name
        }

        if let parent = msg.parent {
            if parent.is_valid(), let parentEntity = world.entity_list.get(parent) {
                parentEntity.entity.addChild(entity)
            } else {
                default_log.warning("Unparenting")
                world.root_entity.addChild(entity)
            }
        }
    }
    
    private func applyTransform(_ world: NoodlesWorld, _ msg: MsgEntityCreate) {
        guard let tf = msg.tf else { return }

        switch tf {
        case .matrix(let mat):
            if let gesture = entity.gestureComponent {
                let shared = EntityGestureState.shared
                if shared.targetedEntity == entity,
                   shared.isDragging || shared.isRotating || shared.isScaling {
                    entity.components[GestureSupportComponent.self]?.pending_transform = mat
                    default_log.debug("Delaying transform update for entity '\(self.entity.name)' due to active gesture")
                }
            } else {
                entity.move(to: mat, relativeTo: entity.parent, duration: 0.1)
            }

            

        case .qr_code(_), .geo_coordinates(_):
            // TODO: Support additional transform types
            default_log.warning("Transform type not implemented for entity '\(self.entity.name)'")
        }
    }
    
    private func updateRenderRepresentation(_ world: NoodlesWorld, _ msg: MsgEntityCreate) {
        if msg.null_rep != nil {
            unset_representation(world)
            default_log.debug("Entity '\(self.entity.name)' cleared representation")
            return
        }

        guard let rep = msg.rep else { return }

        // Resolve geometry and instance view references
        guard let geometry = world.geometry_list.get(rep.mesh) else {
            default_log.error("Missing geometry for entity '\(self.entity.name)'")
            return
        }

        let instanceView = rep.instances.flatMap { inst in
            world.buffer_view_list.get(inst.view)
        }

        let prep = NooEntityRenderPrep(geometry: geometry, instance_view: instanceView)

        // Build sub-entities and install them
        let newSubs = build_sub_render_representation(rep, prep, world)

        unset_representation(world)

        for sub in newSubs {
            add_sub(sub)
        }

        default_log.debug("Entity '\(self.entity.name)' updated render representation with \(newSubs.count) sub-entities")
    }
    
    private func updatePhysics(_ world: NoodlesWorld, _ msg: MsgEntityCreate) {
        guard let physicsRefs = msg.physics, let firstID = physicsRefs.first else { return }

        // Remove old physics debug visuals if present
        if let debugEntity = physics_debug {
            debugEntity.removeFromParent()
            entity.removeChild(debugEntity)
            physics_debug = nil
        }

        guard let physics = world.physics_list.get(firstID),
              let advector = physics.advector_state else {
            default_log.warning("Physics or advector state missing for entity '\(self.entity.name)'")
            return
        }

        let context = ParticleContext(
            advect_multiplier: 10.0,
            time_delta: 1 / 60.0,
            max_lifetime: 10.0,
            bb_min: float_to_packed(advector.bb.min),
            bb_max: float_to_packed(advector.bb.max),
            vfield_dim: pack_cast(advector.velocity.dims),
            number_particles: UInt32(advector.num_particles),
            spawn_range_start: 0,
            spawn_range_count: 0,
            spawn_at: MTLPackedFloat3Make(0.0, 0.0, 0.0),
            spawn_at_radius: 0.25
        )

        let component = make_advection_component(context: context)

        component.velocity_vector_field.contents().copyMemory(
            from: advector.velocity.array,
            byteCount: component.velocity_vector_field.length
        )

        entity.components.set(component)
        default_log.info("Advection component added to entity '\(self.entity.name)'")

        // Debug visualization entity
        let debugEnt = Entity()
        debugEnt.position = .zero

        let resource = try? MeshResource(from: component.glyph_system.low_level_mesh)
        if let mesh = resource {
            let model = ModelComponent(mesh: mesh, materials: [PhysicallyBasedMaterial()])
            debugEnt.components.set(model)
            debugEnt.components.set(AdvectionSpawnComponent())
            entity.addChild(debugEnt)
            physics_debug = debugEnt
            default_log.debug("Added advection debug visuals to entity '\(self.entity.name)'")
        }
    }

    private func updateMethodsAndGestures(_ world: NoodlesWorld, _ msg: MsgEntityCreate) {
        guard let methods_list = msg.methods_list else {
            // Remove gestures if methods are cleared
            return
        }

        let methods = methods_list.compactMap {
            world.methods_list.get($0)
        }
        
        abilities = SpecialAbilities(methods)
        
        if abilities.can_move || abilities.can_rotate || abilities.can_scale || abilities.can_activate {
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
    
    private func updateVisibility(_ world: NoodlesWorld, _ msg: MsgEntityCreate) {
        // Toggle visibility
        if let isVisible = msg.visible {
            entity.isEnabled = isVisible
            default_log.debug("Entity '\(self.entity.name)' visibility set to \(isVisible)")
        }

        // Add billboard component
        if let billboard = msg.billboard {
            if (billboard) {
                entity.components.set(BillboardComponent())
                default_log.debug("Entity '\(self.entity.name)' set to billboard mode")
            } else {
                entity.components.remove(BillboardComponent.self)
            }
            
        }

        // Add occlusion component
        if let occlusion = msg.occlusion {
            if occlusion {
                for sub_entity in sub_entities {
                    if var model = sub_entity.components[ModelComponent.self] {
                        model.materials[0] = OcclusionMaterial()
                    }
                }
                default_log.debug("Entity '\(self.entity.name)' set to be occluding")
            }
            
        }
    }


    
    /// Handles a new transform matrix update, accounting for gesture interactions.
    /// If the entity is currently being manipulated, transformation is deferred.
    /// - Parameters:
    ///   - world: The `NoodlesWorld` context.
    ///   - transform: The new world-space transform matrix to apply.
    func handle_new_tf(_ world: NoodlesWorld, transform: simd_float4x4) {
        // If the user is dragging and a transform update comes in, we can delay it
        // until they are done
        if entity.gestureComponent != nil {
            let shared = EntityGestureState.shared
            if shared.targetedEntity == entity {
                if shared.isDragging || shared.isRotating || shared.isScaling {
                    //print("Delaying transform update for entity!")
                    entity.components[GestureSupportComponent.self]?.pending_transform = transform
                    return;
                }
            }
        }
        
        entity.move(to: transform, relativeTo: entity.parent, duration: 0.1)
    }
    
    /// Installs gesture controls (drag, rotate, scale, tap) based on entity abilities.
    /// Also adds hover and input target components for interaction.
    /// - Parameter world: The current `NoodlesWorld` context.
    func install_gesture_control(_ world: NoodlesWorld) {
        print("Installing gesture controls...")
        
        // this gets called AFTER we do a render rep
        // if there is NO render rep, nothing will work
        
        let gesture = GestureComponent(
            canDrag: abilities.can_move,
            pivotOnDrag: false,
            canScale: abilities.can_scale,
            canRotate: abilities.can_rotate,
            canTap: abilities.can_activate
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
    
    /// Called when the entity is first created from a message.
    /// Adds it to the scene, applies naming, and runs shared creation logic.
    /// - Parameter world: The current `NoodlesWorld` context.
    @MainActor
    func create(world: NoodlesWorld) {
        world.root_entity.addChild(entity)
        
        //print("Creating \(last_info.id)")
        
        entity.name = "noo_\(String(describing: last_info.id))"

        common(world: world, msg: last_info)
    }
    
    /// Clears the visual representation (geometry/instances) from the entity.
    /// - Parameter world: The current `NoodlesWorld` context.
    func unset_representation(_ world: NoodlesWorld) {
        clear_subs(world)
    }
    
    /// Adds a sub-entity as a child of this entity and tracks it for cleanup.
    /// - Parameter ent: The sub-entity to attach.
    func add_sub(_ ent: Entity) {
        sub_entities.append(ent)
        
        entity.addChild(ent)
    }
    
    /// Builds an instanced rendering representation from buffer data and patch geometry.
    /// Uploads instance transforms to GPU, computes bounding box, and spawns the model entity.
    /// - Parameters:
    ///   - src: Instance source containing optional bounds.
    ///   - prep: Precomputed geometry + instance view references.
    ///   - world: The current `NoodlesWorld` context.
    /// - Returns: An array of entities and their computed bounding box, or `nil` on failure.
    @MainActor
    func build_instance_representation(_ src: InstanceSource,
                                       _ prep: NooEntityRenderPrep,
                                       _ world: NoodlesWorld
    ) -> ([Entity], BoundingBox)? {
        
        guard let v = prep.instance_view else {
            default_log.warning("missing instance buffer view")
            return nil
        }
        
        guard let instance_data = v.get_slice(offset: 0) else {
            default_log.warning("missing instance buffer data")
            return nil
        }
        
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
        
        guard let glyph = patchToGlyph(prep.geometry.info.patches.first, world: world) else {
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
    
    /// Builds one or more sub-entities from geometry and rendering metadata.
    /// If instancing is present, delegates to `build_instance_representation`. Otherwise,
    /// creates one sub-entity per mesh/material pair.
    /// - Parameters:
    ///   - rep: The render representation message.
    ///   - prep: Cached geometry + instance view.
    ///   - world: The current `NoodlesWorld` context.
    /// - Returns: Array of generated sub-entities.
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
                var this_mat = mat;
                
                if let b = self.last_info.occlusion {
                    if b {
                        this_mat = OcclusionMaterial()
                    }
                }
                
                let new_entity = ModelEntity(mesh: mesh, materials: [this_mat])
                subs.append(new_entity)
            }
        }
        
        return subs
    }
    
    /// Enables or disables interaction input for the entity (e.g., collision + input target).
    /// Automatically computes collision bounds from sub-entity geometry.
    /// - Parameter enabled: Whether input should be enabled or not.
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
    
    /// Applies an update message to the entity, re-running shared creation logic with new data.
    /// - Parameters:
    ///   - world: The current `NoodlesWorld` context.
    ///   - update: The message containing updated entity data.
    @MainActor
    func update(world: NoodlesWorld, _ update: MsgEntityCreate) {
        common(world: world, msg: update)
        last_info = update
    }
    
    /// Detaches and removes all sub-entities from this entity.
    /// - Parameter world: The current `NoodlesWorld` context.
    private func clear_subs(_ world: NoodlesWorld) {
        //print("Clearing subs!")
        for sub_entity in sub_entities {
            entity.removeChild(sub_entity)
        }
        sub_entities.removeAll(keepingCapacity: true)
    }
    
    /// Completely removes this entity from the scene, detaching from parent and clearing sub-entities.
    /// - Parameter world: The current `NoodlesWorld` context.
    func destroy(world: NoodlesWorld) {
        clear_subs(world)
        entity.removeFromParent()
        //print("Deleting \(last_info.id)")
    }
    
}

/// Describes supported vector formats for vertex attributes (e.g., 2D or 3D vectors).
/// Used when interpreting raw buffer data into structured vertex types.
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

/// Converts raw buffer data into an array of normalized `SIMD2<UInt16>` texture coordinates.
/// Y-values are flipped vertically for texture-space alignment.
/// - Parameters:
///   - data: Raw buffer containing packed u16vec2 values.
///   - vcount: Number of vertices to read.
///   - stride: Byte stride between each element.
/// - Returns: Array of flipped and normalized `SIMD2<UInt16>` coordinates.
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

/// Converts raw buffer data into an array of `SIMD2<Float>` texture coordinates.
/// Y-values are flipped vertically to match standard texture-space conventions.
/// - Parameters:
///   - data: Raw buffer containing packed float2 values.
///   - vcount: Number of vertices to read.
///   - stride: Byte stride between each element.
/// - Returns: Array of vertically flipped texture coordinates.
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

/// Converts raw buffer data into an array of `SIMD3<Float>` vertex positions or normals.
/// Currently only supports the `.V3` format.
/// - Parameters:
///   - data: Raw binary data buffer.
///   - fmt: Expected vector format (only `.V3` supported).
///   - vcount: Number of vertices to read.
///   - stride: Byte stride between each element.
/// - Returns: Array of 3D float vectors.
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

/// Parses a `Data` blob into an array of `simd_float4x4` matrices.
/// Assumes tightly packed, aligned 4x4 float matrices.
/// - Parameter data: Raw buffer to interpret.
/// - Returns: Array of 4x4 matrices.
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

/// Converts a 4D vector into a 3D vector by dropping the `w` component.
/// - Parameter v: Input `simd_float4`.
/// - Returns: The 3D portion of the vector.
func vec4_to_vec3(_ v : simd_float4) -> simd_float3 {
    return simd_float3(v.x, v.y, v.z)
}

/// Transforms a 3D vector by a 4x4 matrix using homogeneous coordinates.
/// Applies perspective division if needed.
/// - Parameters:
///   - mat: Transformation matrix.
///   - v: Input 3D vector.
/// - Returns: Transformed 3D vector.
func matrix_multiply(_ mat: simd_float4x4, _ v : simd_float3) -> simd_float3 {
    let v4 = simd_float4(v, 1.0)
    let ret = matrix_multiply(mat, v4)
    return vec4_to_vec3(ret) / ret.w
}

// MARK: Advection

/// Uniquely identifies a particle in an advected line system based on its line and offset index.
/// Used for correlating particles with their source data in stream flow simulations.
struct AdvectionID : Equatable {
    let line_id: UInt32
    let offset : UInt32
}

/// Stores computed state from a stream flow simulation including bounds, particles, and velocity field.
/// Converts flow lines and tetrahedral data into a structured velocity grid for particle simulation.
@MainActor
class NooAdvectorState {
    var lines: [NooFlowLine]
    
    var bb = BoundingBox()
    
    var num_particles = 1000
    
    var velocity : Grid3D<simd_float3>
    
    init(sf: StreamFlowInfo, world: NoodlesWorld) {
        print("Creating debug flow geom")
        
        guard let buffer_view = world.buffer_view_list.get(sf.data) else {
            default_log.warning("missing advector buffer view")
            lines = []
            velocity = Grid3D(1, 1, 1, .zero)
            return
        }
        
        // since we cant do offsets of offsets here...
        guard let data = buffer_view.get_slice(offset: Int64(sf.offset)) else {
            default_log.warning("missing advector buffer slice")
            lines = []
            velocity = Grid3D(1, 1, 1, .zero)
            return
        }
        
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

/// Represents a physics simulation context, including advection and flow line support.
/// Converts tetrahedral flow data into a velocity grid and exposes it to particle systems.
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

/// Represents a single per-sample attribute in a flow line (e.g., scalar fields).
/// Holds a flat array of float values matching the number of samples in the parent line.
struct NooFlowAttr {
    var data: [Float32]
}

/// Represents a single line in a flow field, consisting of sample positions and attributes.
/// Lines are extracted from binary data and can be visualized or used for simulation input.
struct NooFlowLine {
    var sample_count: UInt32
    
    var positions: [SIMD3<Float>]
    
    var attribs: [NooFlowAttr]
}

/// Extracts a flow line from binary stream flow data, including positions and attributes.
/// Handles position parsing and attribute decoding from a known layout.
/// - Parameters:
///   - data: Full binary stream flow payload.
///   - base_offset: Offset into the data where the line starts.
///   - acount: Number of attributes per sample.
/// - Returns: A tuple with the parsed line and the updated cursor position.
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

/// Central runtime environment managing all components and communication for Ziti.
/// Handles creation, lookup, and deletion of all entity types, as well as message routing and input states.
/// Acts as a scene manager, resource coordinator, and protocol bridge.
@MainActor
public class NoodlesWorld {
    public weak var comm: NoodlesCommunicator?
    
    // This is the entity that we branch all our generated entities off of
    var external_root: Entity
    
    // This is the entity we make visible when things go wrong
    var error_entity: Entity
    
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
    
    var set_item_input_cached : Bool = true
    
    public var root_entity : Entity
    public var root_controller: Entity
    
    //var instance_test: GlyphInstances
    
    @MainActor
    public init(_ root: Entity, _ error_entity: Entity, _ doc_method_list: MethodListObservable, initial_offset: simd_float3 = .zero) async {
        self.visible_method_list = doc_method_list
        self.error_entity = error_entity
        
        self.error_entity.isEnabled = false
        
        external_root = root
        
        root_controller = await makeRootHandleEntity();
        
        let bb = root_controller.visualBounds(relativeTo: root_controller.parent)
        var gesture = GestureComponent(canDrag: true, pivotOnDrag: false, canScale: true, canRotate: true)
        gesture.delegateToParent = true
        gesture.lockRotateUpAxis = true
        gesture.canScale = false
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
        
        set_all_entity_input(enabled: true)
        
        print("New NOODLES world", Unmanaged.passUnretained(self).toOpaque())
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

/// A high-level representation of a method available to the UI or runtime for invocation.
/// Includes metadata for display, context, and documentation.
public struct AvailableMethod: Identifiable, Hashable {
    public var id = UUID()
    public var noo_id : NooID
    public var name : String
    public var doc : String?
    public var context: NooID?
    public var context_type: String
}

/// An observable container for available methods. Used to power UI updates in SwiftUI.
/// Tracks time-related methods and provides lookup by name.
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
