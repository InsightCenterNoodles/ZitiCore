//
//  InstanceTypesMirror.swift
//  ZitiCore
//
//  Created by Nicholas Brunhart-Lupo on 1/14/25.
//

import Foundation
import Metal

struct ParticleVertex {
    var position: MTLPackedFloat3
    var normal: MTLPackedFloat3
    var uv: (Float, Float)
}

struct InstanceDescriptor {
    let instance_count: uint
    let in_vertex_count: uint
    let in_index_count: uint
}

struct ParticleContext {
    // meters per second scalar
    let advect_multiplier: Float
    
    // time, in seconds, since last frame
    var time_delta: Float
    
    // time, in seconds, a particle should live
    let max_lifetime: Float
    
    //bounds of box
    let bb_min: MTLPackedFloat3
    let bb_max: MTLPackedFloat3
    
    // dimensions of the grid
    let vfield_dim: (Int32, Int32, Int32)
    
    let number_particles: uint
    var spawn_range_start: uint
    var spawn_range_count: uint
    var spawn_at: MTLPackedFloat3
    var spawn_at_radius: Float
};

struct AParticle {
    let position : MTLPackedFloat3
    let lifetime : Float
};

#if DEBUG
struct InstanceTypesMirrorChecker {
    static func check() -> Bool {

        assert(MemoryLayout<ParticleVertex>.size == 32)
        assert(MemoryLayout<InstanceDescriptor>.size == (3*4))
        assert(MemoryLayout<ParticleContext>.size == (1 + 1 + 1 + 3 + 3 + 3 + 3 + 3 + 1)*4)
        assert(MemoryLayout<AParticle>.size == (4*4))

        return true
    }
    
    static let check_item : Bool = check()
}
#endif
