//
//  DirectUpload.metal
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/6/24.
//

#include <metal_stdlib>
using namespace metal;

kernel void direct_upload_vertex(device char* in_buffer [[buffer(0)]],
                                 device char* out_buffer [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
    out_buffer[id] = in_buffer[id];
}
