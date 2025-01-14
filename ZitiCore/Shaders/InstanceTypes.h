//
//  InstanceTypes.h
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/12/24.
//

#pragma once

#include <simd/simd.h>

#ifndef __METAL__
typedef struct { float x; float y; float z; } packed_float3;
typedef struct { int x; int y; int z; }       packed_int3;
typedef unsigned uint;
#endif

// THESE TYPES MUST BE SYNCED WITH INSTANCETYPESMIRROR!!!!
// Manual sync to deal with the lack of briging headers

// A vertex to be used in the pseudo instance/particle system
struct ParticleVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 uv; // we had short here, but that breaks when we do scaling
};

// Core instance information to be used in the pseudo instance/particle system
struct InstanceDescriptor {
    uint instance_count;
    uint in_vertex_count;
    uint in_index_count;
};


struct ParticleContext {
    // meters per second scalar
    float advect_multiplier;
    
    // time, in seconds, since last frame
    float time_delta;
    
    // time, in seconds, a particle should live
    float max_lifetime;
    
    //bounds of box
    packed_float3 bb_min;
    packed_float3 bb_max;
    
    // dimensions of the grid
    packed_int3 vfield_dim;
    
    unsigned number_particles;
    unsigned spawn_range_start;
    unsigned spawn_range_count;
    packed_float3 spawn_at;
    float spawn_at_radius;
};

struct AParticle {
    packed_float3 position;
    float lifetime;
};
