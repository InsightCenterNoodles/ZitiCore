//
//  ComputeContext.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/5/24.
//

import Foundation
import Metal

class ComputeContext {
    static let shared = ComputeContext()
    
    let device: MTLDevice
    let command_queue: MTLCommandQueue
    let library: MTLLibrary
    
    let direct_upload_function: MTLFunction
    
    let pseudo_inst_vertex: ComputeFunction
    let pseudo_inst_index: ComputeFunction
    
    let advect_particles: ComputeFunction
    
    init(device: MTLDevice? = nil, commandQueue: MTLCommandQueue? = nil) {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            fatalError("Unable to build Metal device.")
        }
        guard let commandQueue = commandQueue ?? device.makeCommandQueue() else {
            fatalError("Unable to build command queue for given metal device")
        }
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Unable to find code library")
        }
        self.device = device
        self.command_queue = commandQueue
        self.library = library
        
        self.direct_upload_function = library.makeFunction(name: "direct_upload_vertex")!
        
        self.pseudo_inst_vertex = .init(name: "construct_from_inst_array", library, device)
        self.pseudo_inst_index = .init(name: "construct_inst_index", library, device)
        self.advect_particles = .init(name: "advect_particles", library, device)
        
        let max_threadgroup_size = device.maxThreadsPerThreadgroup
        print("Max Threadgroup Size: \(max_threadgroup_size)")
    }
    
    
    /// Computed rounded threadgroups for platforms that cannot do dynamically tiled groups. Use with `dispatchThreadgroups`
    /// - Parameters:
    ///   - compute_threads: Threads you are wishing to launch
    ///   - threadgroup_size: Threadgroup setup (i.e. [32, 1, 1], etc)
    /// - Returns: Threads per threadgroup
    func get_threadgroups(_ compute_threads: MTLSize, threadgroup_size: MTLSize) -> MTLSize {
        return MTLSize(
            width: next_multiple_of(value: compute_threads.width, multiple: threadgroup_size.width),
            height: next_multiple_of(value: compute_threads.height, multiple: threadgroup_size.height),
            depth: next_multiple_of(value: compute_threads.depth, multiple: threadgroup_size.depth)
        )
    }
}

private func next_multiple_of(value: Int, multiple: Int) -> Int {
    return multiple * Int(ceil(Double(value)/Double(multiple)))
}

class ComputeFunction {
    let mtl_func: MTLFunction
    let pipeline_state: MTLComputePipelineState
    
    init(name: String, _ library: MTLLibrary, _ device: MTLDevice) {
        mtl_func = library.makeFunction(name: name)!
        pipeline_state = try! device.makeComputePipelineState(function: mtl_func)
    }
    
    func new_pipeline_state() -> MTLComputePipelineState{
        try! pipeline_state.device.makeComputePipelineState(function: mtl_func)
    }
}


class ComputeSession {
    var command_buffer: MTLCommandBuffer
    var scope : MTLCaptureScope?
    
    init?() {
        // Build a new command buffer
        guard let cb = ComputeContext.shared.command_queue.makeCommandBuffer() else {
            default_log.critical("Unable to obtain command buffer.")
            return nil
        }
        
        self.command_buffer = cb
    }
    
    func with_encoder(_ function: (MTLComputeCommandEncoder) -> Void) {
        guard let enc = command_buffer.makeComputeCommandEncoder() else {
            default_log.critical("Unable to obtain command buffer encoder.")
            return
        }
        
        function(enc)
        
        enc.endEncoding()
    }
    
    deinit {
        command_buffer.commit()
        //command_buffer.waitUntilCompleted()
        
        if let s = scope {
            s.end()
        }
    }
    
}

func compute_dispatch_1D(enc: MTLComputeCommandEncoder, num_threads: Int, groups: Int) {
    //Note that the VP cannot do dynamic tiling, so we have to round up ourselves
    let dispatch_size = MTLSize(width: num_threads, height: 1, depth: 1)
    let threads_per_threadgroup = MTLSize(width: 32, height: 1, depth: 1)
    let dispatch_threads = ComputeContext.shared.get_threadgroups(dispatch_size, threadgroup_size: threads_per_threadgroup)
    enc.dispatchThreadgroups(dispatch_threads, threadsPerThreadgroup: threads_per_threadgroup)
}
