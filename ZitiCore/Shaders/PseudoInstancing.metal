//
//  PseudoInstancing.metal
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/12/24.
//

#include <metal_stdlib>
using namespace metal;

#include "InstanceTypes.h"

// Matrix layout
//
// px py pz ?   // translate
// tx ty su sv  // texture translate + scale
// rx ry rz rw  // rotation
// sx sy sz ?   // scale

/// Rotate a point around the origin by a quaternion
float3 rotate_point(float3 p, float4 quat) {
    return p + 2.0 * cross(quat.xyz, cross(quat.xyz, p) + quat.w * p);
}

float2 texcoord_offset(float2 tex_coords, float2 normalized_offset, float2 normalized_scale) {
    
    tex_coords *= normalized_scale;
    tex_coords += normalized_offset;
    
    return tex_coords;
}

/// Compute a transformed vertex given an instance matrix pack
void transform_glyph_vertex(device ParticleVertex const* in_verts,
                            device ParticleVertex* out_verts,
                            float4x4 instance,
                            uint vertex_count) {
    float3 inst_position = instance[0].xyz;
    float4 inst_texture  = instance[1]; // color not used. pending removal?
    float4 inst_rotation = instance[2];
    float3 inst_scale    = instance[3].xyz;
    //float2 inst_uv       = inst_texture.xy;
    
    for (uint i = 0; i < vertex_count; i++) {
        device auto& in_v = in_verts[i];
        device auto& out_v = out_verts[i];
        
        out_v.position = rotate_point(in_v.position*inst_scale, inst_rotation) + inst_position;
        out_v.normal   = normalize(rotate_point(in_v.normal, inst_rotation));
        out_v.uv       = texcoord_offset(in_v.uv, inst_texture.xy, inst_texture.zw);
        //out_v.uv       = in_v.uv;
    }
}

/// Compute instances of a glyph, transforming and copying instances to a new buffer (vertex version)
kernel void construct_from_inst_array(constant InstanceDescriptor& description [[buffer(0)]],
                                      device float4x4*             instance_buffer [[buffer(1)]],
                                      device ParticleVertex const* input_vertex_list [[buffer(2)]],
                                      device ParticleVertex*       new_vertex_list [[buffer(3)]],
                                      uint id [[thread_position_in_grid]]) {
    
    if (id >= description.instance_count) {
        return;
    }
    
    //const uint instance_count = description.instance_count;
    const uint vertex_count = description.in_vertex_count;
    
    // each thread here corresponds with a single instance
    device float4x4& this_instance = instance_buffer[id];
    
    // we are taking the range of glyph vertex, and writing updated versions to this range
    // these should be exclusive, so totally parallel
    device ParticleVertex* destination = new_vertex_list + (vertex_count*id);
    
    transform_glyph_vertex(input_vertex_list, destination, this_instance, vertex_count);
}

/// Compute instances of a glyph, transforming and copying instances to a new buffer (index version)
kernel void construct_inst_index(constant InstanceDescriptor& description [[buffer(0)]],
                                 device ushort const* input_index_list [[buffer(1)]],
                                 device uint*         new_index_list [[buffer(2)]],
                                 uint id [[thread_position_in_grid]]) {
    
    if (id >= description.instance_count) {
        return;
    }
    
    const uint index_count = description.in_index_count;
    const uint vertex_count = description.in_vertex_count;
    
    // each thread here corresponds with a single instance
    
    device uint* destination = new_index_list + (index_count*id);
    
    for (uint i = 0; i < index_count; i++) {
        uint index = input_index_list[i];
        
        index += (vertex_count * id);
        
        destination[i] = index;
    }
}
