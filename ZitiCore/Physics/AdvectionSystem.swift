//
//  AdvectionSystem.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 5/6/24.
//

import Foundation
import SwiftUI
import RealityKit

// MARK: Advection Component

/// Advection information for an entity.
struct ParticleAdvectionComponent: Component {
    // compute state
    let compute_state: MTLComputePipelineState
    
    // 3d grid of velocity info
    let velocity_vector_field : MTLBuffer
    
    // mat4s of particle info
    let glyph_info: MTLBuffer
    
    // vec of AParticle
    let particle_info: MTLBuffer
    
    // context
    var particle_context: ParticleContext
    
    // glyph
    var glyph_system: GlyphInstances
    
    // last compute buffer
    var command_buffer: MTLCommandBuffer?
    
    var capture_bounds: MTLCaptureScope
}

@MainActor
func make_advection_component(context: ParticleContext) -> ParticleAdvectionComponent {
    // should be a packed list of 3 floats, 4 bytes each
    let vel_fld_len = context.vfield_dim.0 * context.vfield_dim.1 * context.vfield_dim.2 * 3 * 4
    
    let mat4len = Int(context.number_particles) * MemoryLayout<float4x4>.stride
    
    let part_len = Int(context.number_particles) * MemoryLayout<AParticle>.stride
    
    let glyph_info = make_glyph(shape_cube)
    
    //print("Making advection component for \(context.number_particles)")
    //print("Glyph info \(MemoryLayout<float4x4>.stride)")
    
    let cap = MTLCaptureManager.shared().makeCaptureScope(device: ComputeContext.shared.device)
    
    cap.label = "AdvectionCheck"
    //MTLCaptureManager.shared().defaultCaptureScope = cap
    
    return ParticleAdvectionComponent(
        compute_state: ComputeContext.shared.advect_particles.new_pipeline_state(),
        velocity_vector_field: ComputeContext.shared.device.makeBuffer(length: Int(vel_fld_len), options: .storageModeShared)!,
        glyph_info: ComputeContext.shared.device.makeBuffer(length: mat4len, options: .storageModeShared)!,
        particle_info: ComputeContext.shared.device.makeBuffer(length: part_len, options: .storageModeShared)!,
        particle_context: context,
        glyph_system: GlyphInstances(
            instance_count: context.number_particles,
            description: GPUGlyphDescription(from: glyph_info)
        ),
        capture_bounds: cap
    )
    
}

class GlobalAdvectionSettings {
    static var shared = GlobalAdvectionSettings()
    
    // this should be in meters per second
    var advection_speed = 1.0;
}

func packed_to_float(_ packed: MTLPackedFloat3) -> SIMD3<Float> {
    return SIMD3<Float>(packed.x, packed.y, packed.z)
}

func float_to_packed(_ v: SIMD3<Float>) -> MTLPackedFloat3 {
    return MTLPackedFloat3Make(v.x, v.y, v.z)
}

func pack_cast(_ int: simd_uint3) -> (Int32, Int32, Int32) {
    return (Int32(int.x), Int32(int.y), Int32(int.z))
}

/// A system that advects particles. Scans for all ParticleAdvectionComponents and runs compute shaders
struct AdvectionSystem: System {
    static let query = EntityQuery(where: .has(ParticleAdvectionComponent.self))

    init(scene: RealityKit.Scene) {}
    
    @MainActor
    static func handle_entity(e: Entity, scene_context: SceneUpdateContext) {
        guard var component: ParticleAdvectionComponent = e.components[ParticleAdvectionComponent.self] else {
            return
        }
        
        //print("Advecting for \(e.hashValue)")
        
        // we can skip checks at the start
        if let buff = component.command_buffer {
            
            if buff.status != .completed {
                default_log.warning("Skipping advection for this frame")
                return
            }
            
        }
        
        let time_delta = GlobalAdvectionSettings.shared.advection_speed * scene_context.deltaTime;
        
        component.particle_context.time_delta = Float(time_delta)
        
        // start compute
        
        component.capture_bounds.begin()
        
        // Build a new session
        guard let compute_session = ComputeSession() else {
            default_log.critical("Skipping instance update.")
            return
        }
        
        component.command_buffer = compute_session.command_buffer
        
        compute_session.scope = component.capture_bounds
        
        compute_session.with_encoder {
            // run advection
            
            $0.setComputePipelineState(component.compute_state)
            $0.setBytes(&component.particle_context, length: MemoryLayout.size(ofValue: component.particle_context), index: 0)
            $0.setBuffer(component.glyph_info, offset: 0, index: 1)
            $0.setBuffer(component.particle_info, offset: 0, index: 2)
            $0.setBuffer(component.velocity_vector_field, offset: 0, index: 3)
            
            compute_dispatch_1D(enc: $0, num_threads: Int(component.particle_context.number_particles), groups: 32)
        }
        
        let bb = BoundingBox(
            min: packed_to_float(component.particle_context.bb_min),
            max: packed_to_float(component.particle_context.bb_max)
        )
        
        component.glyph_system.update(instance_buffer: component.glyph_info, bounds: bb, session: compute_session)
        
        // when we are done, update flag
        //compute_session.command_buffer.encodeSignalEvent(component.busy_flag, value: component.busy_counter)
        
        e.components.set(component)
        
        //print("Completing buffer for \(e.hashValue)")
    }

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            Self.handle_entity(e: entity, scene_context: context)
        }
    }
}

// MARK: Advection Spawn

struct AdvectionSpawnComponent : Component {
    var spawn_count = 10
    var spawn_radius = 0.5
}

struct AdvectionSpawnSystem: System {
    static var dependencies: [SystemDependency] {
        [.before(AdvectionSystem.self)]
    }
    
    static let query = EntityQuery(where: .has(AdvectionSpawnComponent.self))
    static let dest_query = EntityQuery(where: .has(ParticleAdvectionComponent.self))
    
    static let mesh_resource : MeshResource = .generateBox(size: 0.1)

    init(scene: RealityKit.Scene) {}
    
    func schedule_delete(_ e: Entity) {
        e.removeFromParent()
    }
    
    func handle_entity(e: Entity, context: SceneUpdateContext) {
        //print("Spawner running for \(e.hashValue)")
        // ONLY WORKS WITH A SINGLE SPAWNER FOR NOW
        guard let component = e.components[AdvectionSpawnComponent.self] else {
            schedule_delete(e);
            return
        }
        
        for de in context.entities(matching: Self.dest_query, updatingSystemWhen: .rendering) {
            guard var particle_component = de.components[ParticleAdvectionComponent.self] else {
                continue
            }
            
            let de_position = e.convert(position: .zero, to: de)
            let de_radius = (e.convert(position: .init(Float(component.spawn_radius),0,0), to: de) - de_position).x
            
            var ctx = particle_component.particle_context
            
            ctx.spawn_at = MTLPackedFloat3Make(de_position.x, de_position.y, de_position.z)
            ctx.spawn_at_radius = de_radius
            
            let new_head = (ctx.spawn_range_start + ctx.spawn_range_count) % ctx.number_particles
            
            ctx.spawn_range_start = new_head
            ctx.spawn_range_count = UInt32(component.spawn_count)
            
            //print("Adding \(component.spawn_count) to \(de.hashValue) ( \(ctx.spawn_range_start) )")
            
            // save
            particle_component.particle_context = ctx
            de.components.set(particle_component)
        }
        
    }

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            handle_entity(e: entity, context: context)
        }
    }
}
