//
//  Advect.metal
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/28/24.
//

#include <metal_stdlib>
using namespace metal;

#include "InstanceTypes.h"

/// Linear address for a 3D coordinate. 3D Grid coordinates required
int index(int3 at, int3 dims) {
    return at.x + dims.x * at.y + dims.x * dims.y * at.z;
}

/// Look up a value in a 3D grid, with a linear representation. Grid dimensions required
float3 lookup(int3 at, int3 dims, device packed_float3* field) {
    return field[index(at, dims)];
}

/// Trilinear sample for a 3D Grid at a point p
float3 lsample(device packed_float3* field, int3 dims, float3 p) {
    auto fl_p = floor(p);
    auto x0 = fl_p[0];
    auto x1 = x0 + 1;
    auto y0 = fl_p[1];
    auto y1 = y0 + 1;
    auto z0 = fl_p[2];
    auto z1 = z0 + 1;
    auto xd = p[0] - x0;
    auto yd = p[1] - y0;
    auto zd = p[2] - z0;
    
    auto g000 = lookup(int3(x0, y0, z0), dims, field);
    auto g001 = lookup(int3(x0, y0, z1), dims, field);
    auto g010 = lookup(int3(x0, y1, z0), dims, field);
    auto g011 = lookup(int3(x0, y1, z1), dims, field);
    
    auto g100 = lookup(int3(x1, y0, z0), dims, field);
    auto g101 = lookup(int3(x1, y0, z1), dims, field);
    auto g110 = lookup(int3(x1, y1, z0), dims, field);
    auto g111 = lookup(int3(x1, y1, z1), dims, field);
    
    auto c00 = mix(g000, g100, xd);
    auto c10 = mix(g010, g110, xd);
    auto c01 = mix(g001, g101, xd);
    auto c11 = mix(g011, g111, xd);
    auto c0 = mix(c00, c10, yd);
    auto c1 = mix(c01, c11, yd);
    return mix(c0, c1, zd);
}

/// ask if a point is inside a bounding box
bool point_in_bounding_box(float3 p, float3 bb_min, float3 bb_max) {
    return (p.x >= bb_min.x && p.x <= bb_max.x &&
            p.y >= bb_min.y && p.y <= bb_max.y &&
            p.z >= bb_min.z && p.z <= bb_max.z);
}

/// Tell the particle instance that it should not be visible
void mark_particle_instance_dead(device float4x4& p) {
    float4 col0(0.0);
    float4 col1(1);
    float4 col2(0,0,0,1);
    float4 col3(0.0);
    
    p = float4x4(col0, col1, col2, col3);
}

float random(uint seed) {
    seed = (seed ^ 61) ^ (seed >> 16);
    seed = seed + (seed << 3);
    seed = seed ^ (seed >> 4);
    seed = seed * 0x27d4eb2d;
    seed = seed ^ (seed >> 15);
    return float(seed) / float(0xFFFFFFFF);
}

float random_range(float a, float b, uint seed) {
    return a + (b-a) * random(seed);
}

float3 random_sphere(float radius, uint seed) {
    float y = random(seed) * 2 - 1;
    float r = sqrt(1 - y*y);
    float ln = random_range(-M_PI_F, M_PI_H, seed + 1);
    float3 on = float3(r * sin(ln),
                      y,
                      r * cos(ln));
    return on * pow(random(seed + 2), .333);
}

void run_particle_spawn(constant ParticleContext& description, device AParticle& this_particle, uint id) {
    
    uint seed = as_type<uint>(description.time_delta);
    
    seed ^= id;
    
    this_particle.lifetime = description.max_lifetime;
    this_particle.position = random_sphere(description.spawn_at_radius, seed);
}

kernel void advect_particles(constant ParticleContext& description   [[buffer(0)]],
                             device   float4x4*        instance_info [[buffer(1)]],
                             device   AParticle*       particle_info [[buffer(2)]],
                             device   packed_float3*   vector_field  [[buffer(3)]],
                             uint id [[thread_position_in_grid]]) {
    // our ID is a particle
    if (id >= description.number_particles) {
        return;
    }
    
    int3 dims = int3(description.vfield_dim);
    
    device AParticle& this_particle = particle_info[id];
    
    // are we spawning a new particle?
    
    bool do_spawn = false;
    
    auto spawn_range_end = (description.spawn_range_start + description.spawn_range_count) % description.number_particles;
    
    if (spawn_range_end < description.spawn_range_start) {
        // wrap around
        do_spawn = id < spawn_range_end || id >= description.spawn_range_start;
    } else {
        do_spawn = id < spawn_range_end && id >= description.spawn_range_start;
    }
    
    if (do_spawn) {
        // launch a new particle
        run_particle_spawn(description, this_particle, id);
        // and then we go to advect this new particle
    }
    
    // get current particle position, unpack to vec3
    auto current_position = float3(this_particle.position);
    
    // if the particle is outside the grid BB, we can skip this
    if (!point_in_bounding_box(current_position, description.bb_min, description.bb_max)){
        this_particle.lifetime = -1;
    }
    
    // if any particle is dead, skip
    if (this_particle.lifetime <= 0) {
        mark_particle_instance_dead(instance_info[id]);
        return;
    }
    
    // deduct time from the life of the particle
    this_particle.lifetime -= description.time_delta;
    
    // take a sample of the velocity field at the particle point
    // muliplied by the time delta, and scaled by the user control knob
    auto velocity_sample = lsample(vector_field, dims, current_position) * description.advect_multiplier * description.time_delta;
    
    // Advect
    current_position += velocity_sample;
    
    //current_position += float3(1,0,0) * .01;
    
    // update particle information
    this_particle.position = current_position;
    
    // install instance info
    float4 col0(current_position, 0.0);
    float4 col1(1);
    float4 col2(0,0,0,1);
    float4 col3(float3(.5), 0.0);
    
    instance_info[id] = float4x4(col0, col1, col2, col3);
    
}
