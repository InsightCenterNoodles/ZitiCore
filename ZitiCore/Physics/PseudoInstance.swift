//
//  PseudoInstance.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/12/24.
//

import Foundation
import RealityFoundation
import Metal


extension ParticleVertex {
    /// Attributes of the vertex for the low level mesh system
    static var attributes : [LowLevelMesh.Attribute] = [
        .init(semantic: .position, format: .float3, offset: MemoryLayout<ParticleVertex>.offset(of: \ParticleVertex.position)!),
        .init(semantic: .normal, format: .float3, offset: MemoryLayout<ParticleVertex>.offset(of: \ParticleVertex.normal)!),
        .init(semantic: .uv0, format: .float2, offset: MemoryLayout<ParticleVertex>.offset(of: \ParticleVertex.uv)!)
    ]
    
    /// Layout for this vertex type for the low level mesh system
    static var layouts : [LowLevelMesh.Layout] = [
        .init(bufferIndex: 0, bufferOffset: 0, bufferStride: MemoryLayout<ParticleVertex>.stride)
    ]
}

/// Description of a glyph, or mesh that should be copied and transformed for instancing
struct CPUGlyphDescription {
    var vertex: [ParticleVertex]
    var index : [ushort]
    var bounding_box: BoundingBox
}

/// GPU representation of a glyph
///
/// TODO: Merge into a single allocation
struct GPUGlyphDescription {
    var vertex_buffer: MTLBuffer
    var index_buffer: MTLBuffer
    var bounding_box: BoundingBox
    var vertex_count: Int
    var index_count: Int
    
    init(from: CPUGlyphDescription) {
        vertex_buffer = ComputeContext.shared.device.makeBuffer(bytes: from.vertex, length: from.vertex.count * MemoryLayout<ParticleVertex>.stride)!
        
        index_buffer = ComputeContext.shared.device.makeBuffer(bytes: from.index, length: from.index.count * 2)!
        
        bounding_box = from.bounding_box
        
        vertex_count = from.vertex.count
        index_count = from.index.count
    }
}


/// State for the pseudo-instancing system. We take a glyph and use compute shaders to 'splat' the glyph with transformations
class GlyphInstances {
    // The glyph to use
    var glyph: GPUGlyphDescription
    
    let instance_count: UInt32
    
    // Splatted glyphs are stored in this LLM
    var low_level_mesh: LowLevelMesh
    
    // pipeline states for this glyph system
    var vertex_pipeline_state: MTLComputePipelineState
    var index_pipeline_state: MTLComputePipelineState
    
    // Debugging capture boundaries
    var capture_bounds: MTLCaptureScope
    
    @MainActor
    init(instance_count: UInt32, description: GPUGlyphDescription) {
        print("Creating instance system")
        let md = LowLevelMesh.Descriptor(vertexCapacity: Int(instance_count) * description.vertex_count,
                                         vertexAttributes: ParticleVertex.attributes,
                                         vertexLayouts: ParticleVertex.layouts,
                                         indexCapacity: Int(instance_count) * description.index_count,
                                         indexType: .uint32)
        glyph = description
        low_level_mesh = try! LowLevelMesh(descriptor: md)
        self.instance_count = instance_count
        vertex_pipeline_state = ComputeContext.shared.pseudo_inst_vertex.pipeline_state
        index_pipeline_state  = ComputeContext.shared.pseudo_inst_index.pipeline_state
        
        capture_bounds = MTLCaptureManager.shared().makeCaptureScope(device: ComputeContext.shared.device)
    }
    
    /// Enable metal capture for this instancing system
    /// - Parameter name: capture name
    func enable_metal_capture(name: String) {
        capture_bounds.label = name
        MTLCaptureManager.shared().defaultCaptureScope = capture_bounds
    }
    
    @MainActor
    func update(instance_buffer: MTLBuffer, bounds: BoundingBox, session: ComputeSession) {
        
        session.with_encoder {
            
            assert(instance_buffer.length >= (Int(instance_count) * MemoryLayout<float4x4>.stride));
            
            capture_bounds.begin()
            
            // Build description of instance system with basic information
            var descriptor = InstanceDescriptor(instance_count: self.instance_count, in_vertex_count: uint(glyph.vertex_count), in_index_count: uint(glyph.index_count))
            
            // Ask the LLM to give us a new buffer for the vertex info
            // This triggers a ding on the compute recommendation system as it is building and clearing a new buffer, but I'm not sure how to fix that yet.
            let vertex_buffer = low_level_mesh.replace(bufferIndex: 0, using: session.command_buffer)
            
            // Set the vertex pipeline state
            $0.setComputePipelineState(vertex_pipeline_state)
            
            // Load up our buffer table
            $0.setBytes(&descriptor, length: MemoryLayout.size(ofValue: descriptor), index: 0)
            $0.setBuffer(instance_buffer, offset: 0, index: 1)
            $0.setBuffer(glyph.vertex_buffer, offset: 0, index: 2)
            $0.setBuffer(vertex_buffer, offset: 0, index: 3)
            
            // Launch job
            compute_dispatch_1D(enc: $0, num_threads: Int(self.instance_count), groups: 32)
            
            // Ask the LLM for a new buffer for the index side of things. Again, we get a new cleared buffer. Not sure how to mitigate
            let new_index_buffer = low_level_mesh.replaceIndices(using: session.command_buffer)
            
            // Set the index function
            $0.setComputePipelineState(index_pipeline_state)
            
            // Set up the buffer table
            // redundant load below
            //encoder.setBytes(&descriptor, length: MemoryLayout.size(ofValue: descriptor), index: 0)
            $0.setBuffer(glyph.index_buffer, offset: 0, index: 1)
            $0.setBuffer(new_index_buffer, offset: 0, index: 2)
            
            // Launch job
            compute_dispatch_1D(enc: $0, num_threads: Int(self.instance_count), groups: 32)
            
            // Tell the LLM to update the index patch
            low_level_mesh.parts.replaceAll([
                LowLevelMesh.Part(indexOffset: 0,
                                  indexCount: Int(descriptor.instance_count * descriptor.in_index_count),
                                  topology: .triangle,
                                  materialIndex: 0,
                                  bounds: bounds)
            ])
            
            capture_bounds.end()
            
        }
    }
}


class CPUInstanceBuffer {
    // CPU-side instance information, stored as a matrix
    var instances: [float4x4]
    
    // Count of bytes for the instance information. Cached.
    let instances_byte_count: Int
    
    // A buffer holding the GPU-side instance information
    var instance_buffer: MTLBuffer
    
    init(instance_count: Int32) {
        instances = .init(repeating: float4x4(), count: Int(instance_count))
        print("Built fixed cpu instance buffer")
        instances_byte_count = Int(instance_count) * MemoryLayout<float4x4>.stride
        instance_buffer = ComputeContext.shared.device.makeBuffer(length: instances_byte_count, options: .storageModeShared)!
        print("Built fixed gpu instance buffer")
    }
    
    func update() {
        instance_buffer.contents().copyMemory(from: instances, byteCount: instances_byte_count)
    }
    
    var count: Int {
        return instances.count
    }
    
    func over_all(_ f: (_ m: inout float4x4) -> Void) {
        for var inst in instances {
            f(&inst)
        }
    }
    
    func test_fill() {
        for i in 0 ..< instances.count {
            let thing = Float(i) / 10
            instances[i] = float4x4(
                SIMD4<Float>(thing, thing, thing, 0.0), // pos
                SIMD4<Float>(1.0, 1.0, 1.0, 1.0), // col
                SIMD4<Float>(0.0, 0.0, 0.0, 1.0), // rot
                SIMD4<Float>(0.1, 0.1, 0.1, 0.0)  // scale
            )
        }
    }
}
