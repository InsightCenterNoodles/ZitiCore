//
//  VoxelQuery.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 5/7/24.
//

import Foundation
import simd

struct Record<Item: Equatable> : Equatable {
    let point : simd_float3
    let item  : Item
};

class VoxelQueryNode<Item: Equatable> {
    var contents = [Record<Item>]()
}

func any_less(_ a: simd_float3, _ b: simd_float3) -> Bool {
    return any(a .< b)
}

class VoxelQuery<Item: Equatable> {
    typealias Node = VoxelQueryNode<Item>
    typealias StorageType = [Node]
    
    let grid_dims: simd_int3
    let grid_dims_f: simd_float3
    let bounding_min: simd_float3
    let extent: simd_float3
    
    let storage : StorageType
    
    init(min: simd_float3, max: simd_float3, max_bin_count: Int) {
        bounding_min = min
        extent = max - min
        grid_dims_f = ceil(simd_normalize(extent) * Float(max_bin_count))
        grid_dims = simd_int3(grid_dims_f)
        
        let count = Int(grid_dims.x * grid_dims.y * grid_dims.z)
        storage = (0 ..< count).map { _ in VoxelQueryNode<Item>() }
    }
    
    func world_to_grid_coord(_ p: simd_float3) -> simd_int3 {
        //print("world to grid coord")
        let n = (p - bounding_min) / extent
        //dump(n)
        let scaled = n * (grid_dims_f - 1.0)
        //dump(scaled)
        return simd_int3(round(scaled))
    }
    
    func compute_index(_ p: simd_int3) -> Int {
        return Int(p.x + (grid_dims.x * p.y) + (grid_dims.x * grid_dims.y * p.z))
    }
    
    func world_to_index(_ p: simd_float3) -> Int {
        return compute_index(world_to_grid_coord(p))
    }
    
    func lookup(_ p : simd_float3) -> Node? {
        //print("lookup")
        if (any_less(p, bounding_min)) {
            return nil;
        }
        if (any_less(bounding_min+extent,p)) {
            return nil;
        }
        
        let idx = world_to_index(p)
        //print("lookup \(p) \(idx)")
        return storage[idx];
    }

    func install(_ p: Record<Item>) -> Bool {
        guard let node = lookup(p.point) else { return false };
        node.contents.append(p);
        return true
    }

    func search(a: simd_float3, b: simd_float3, _ action: (Record<Item>) -> Void) {
        let ca = clamp(a, min: bounding_min, max: bounding_min+extent);
        let cb = clamp(b, min: bounding_min, max: bounding_min+extent);

        let ai = world_to_grid_coord(ca);
        let bi = world_to_grid_coord(cb);
        
        //print("Search \(ai) \(bi)")
        
        for xi in ai.x ... bi.x {
            for yi in ai.y ... bi.y {
                for zi in ai.z ... bi.z {
                    //print("bin \(xi) \(yi) \(zi)")
                    let index = compute_index(simd_make_int3(xi, yi, zi));
                    for item in storage[index].contents {
                        if any(a .< item.point) && any(item.point .< b) {
                            action(item)
                        }
                    }
                }
            }
        }
    }

    func collect(a: simd_float3, b: simd_float3) -> [Record<Item>] {
        var ret = [Record<Item>]()
        search(a: a, b: b, {
            ret.append($0);
        })
        return ret;
    }
    
}
