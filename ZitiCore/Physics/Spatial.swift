//
//  Spatial.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/22/24.
//

import Foundation
import Accelerate
import RealityFoundation

struct Tetrahedra {
    var a : simd_float3
    var b : simd_float3
    var c : simd_float3
    var d : simd_float3
}

struct TetrahedraIndex {
    var indicies : simd_uint4
    
    func lookup<T>(list: [T]) -> (T, T, T, T) {
        return (list[Int(indicies.x)], list[Int(indicies.y)], list[Int(indicies.z)], list[Int(indicies.w)])
    }
    
    func to_tetrahedra(positions: [simd_float3]) -> Tetrahedra {
        let (a,b,c,d) = lookup(list: positions)
        return Tetrahedra(a: a, b: b, c: c, d: d)
    }
}

protocol Scalable {
    init()
    static func * (lhs: Float, rhs: Self) -> Self
    static func + (lhs: Self, rhs: Self) -> Self
}

extension Float: Scalable {}
extension simd_float3: Scalable {}

struct TetrahedraBarycentric {
    var basis : simd_float3
    var coordinate_mat : simd_float3x3
    
    init(_ t : Tetrahedra) {
        coordinate_mat = simd_float3x3(t.a - t.d, t.b - t.d, t.c - t.d).inverse
        basis = t.d
    }
    
    func to_coordinates(_ p: simd_float3) -> simd_float4 {
        let c = coordinate_mat*(p - basis)
        let l4 = 1 - c.sum()
        return simd_float4(c, l4)
    }
    
    func contains(_ p: simd_float3) -> Bool {
        let c = coordinate_mat * (p - basis)
        
        return all(c .>= simd_float3.zero) && all(c .<= simd_float3.one) && (c.sum() <= 1.0)
    }
    
    func interpolate(_ p: simd_float3, data: simd_float4) -> Float {
        let c = to_coordinates(p)
        return dot(c, data)
    }
    
    func interpolate<T: Scalable>(_ p: simd_float3, data: (T, T, T, T)) -> T {
        let c = to_coordinates(p)
        let part_a = c.x * data.0
        let part_b = c.y * data.1
        let part_c = c.z * data.2
        let part_d = c.w * data.3
        return part_a + part_b + part_c + part_d
    }
}

class Grid3D<T> {
    let dims: simd_uint3
    var array: [T]
    
    init(dims: simd_uint3, repeating: T) {
        self.dims = dims
        let total_cell_count = dims.x * dims.y * dims.z
        self.array = [T](repeating: repeating, count: Int(total_cell_count))
    }
    
    convenience init(_ x: UInt32, _ y: UInt32, _ z: UInt32, _ repeating: T) {
        self.init(dims: simd_uint3(x,y,z), repeating: repeating)
    }
    
    func index(at: simd_uint3) -> Int {
        return Int(at.x + dims.x * at.y + dims.x * dims.y * at.z)
    }
    
    subscript(lx: UInt32, ly: UInt32, lz: UInt32) -> T {
        get {
            return self.array[self.index(at: .init(x: UInt32(lx), y: UInt32(ly), z: UInt32(lz)))]
        }
        set(new_value) {
            self.array[self.index(at: .init(x: UInt32(lx), y: UInt32(ly), z: UInt32(lz)))] = new_value
        }
    }
}

class TetraGridRasterizer {
    var lower_grid : Grid3D<Int32>
    let grid_bounds : BoundingBox
    let resolution : Int
    
    let resolution_scalar : simd_float3
    
    let resolutions_as_float : simd_float3
    let resolutions : simd_uint3
    let deltas : simd_float3
    
    init(grid_bounds: BoundingBox, resolution: Int, positions: [simd_float3], indicies: [TetrahedraIndex]) {
        self.grid_bounds = grid_bounds
        self.resolution = resolution
        
        let bb_range = grid_bounds.extents
        
        self.resolution_scalar = simd_float3(repeating: Float32(resolution) / bb_range.min())
        
        self.resolutions_as_float = ceil(resolution_scalar * bb_range)
        self.resolutions = simd_uint(resolutions_as_float)
        self.deltas = bb_range / resolutions_as_float
        
        self.lower_grid = Grid3D<Int32>(dims: resolutions, repeating: -1)
        
        dump(self.grid_bounds)
        dump(self.resolution)
        dump(self.resolution_scalar)
        dump(self.resolutions_as_float)
        dump(self.resolutions)
        dump(self.deltas)
        
        //var op_q = OperationQueue()
        //op_q.maxConcurrentOperationCount = 1
        
        assert(simd_reduce_min(self.lower_grid.dims) > UInt32(0))
        
        let upper_max = self.lower_grid.dims &- 1
        
        for (i,ti) in indicies.enumerated() {
            
//            if i % 500 == 0 {
//                // we want to make sure we dont overload the process system here
//                op_q.waitUntilAllOperationsAreFinished()
//                op_q = OperationQueue()
//            }
            
//            op_q.addOperation {
                let ta = ti.to_tetrahedra(positions: positions)
                let tb = TetrahedraBarycentric(ta)
                
                // min max of tetra
                let min_bb = min(ta.a, min(ta.b, min(ta.c, ta.d)))
                let max_bb = max(ta.a, max(ta.b, max(ta.c, ta.d)))
                
                // now we need to find which grid points we cover
                var start = simd_uint(floor(((min_bb - grid_bounds.min) / bb_range) * self.resolutions_as_float))
                var end   = simd_uint(ceil(((max_bb - grid_bounds.min) / bb_range) * self.resolutions_as_float))
            
            start = min(start, upper_max)
            end = min(end, upper_max)
                
                if i == 2381178 {
                    print("HERE")
                }
                
                for x in start.x ... end.x {
                    for y in start.y ... end.y {
                        for z in start.z ... end.z {
                            
                            let int_point = simd_uint3(x: x, y: y, z: z)
                            let point = simd_float3(int_point) * self.deltas + grid_bounds.min
                            
                            if !tb.contains(point) {
                                continue
                            }
                            
                            if i == 2381178 {
                                print("Tetra \(i) \(ta)")
                                print("Bounds \(min_bb) \(max_bb)")
                                print("Disc \(start) \(end)")
                                print(" check \(int_point) \(point)")
                            }
                            
                            if self.lower_grid[x,y,z] >= 0 {
                                print("Warning! Tetra overlap on \(int_point)")
                                print("this tetra:")
                                dump(ta)
                                dump(min_bb)
                                dump(max_bb)
                                dump(start)
                                dump(end)
                                
                                print("Other tetra:")
                                let other = Int(self.lower_grid[x,y,z])
                                dump(indicies[other])
                                dump(indicies[other].to_tetrahedra(positions: positions))
                                
                                print("Point in question: \(point)")
                                
                                fatalError("BADNESS")
                            }
                            
                            if i == 2381178 {
                                print("Save \(i) to \( (x,y,z) )")
                            }
                            
                            self.lower_grid[x,y,z] = Int32(i)
                        }
                    }
                }
            }
        
        
        //op_q.waitUntilAllOperationsAreFinished()
    }
    
    
    func interpolate_data<T: Scalable>(indicies: [TetrahedraIndex], positions: [simd_float3], data : [T], repeating: T) -> Grid3D<T> {
        let ret = Grid3D<T>(dims: self.lower_grid.dims, repeating: repeating)
        
        for x in 0 ..< self.lower_grid.dims.x {
            for y in 0 ..< self.lower_grid.dims.y {
                for z in 0 ..< self.lower_grid.dims.z {
                    
                    let tetra_id = self.lower_grid[x,y,z]
                    if tetra_id < 0 {
                        ret[x,y,z] = T()
                        continue
                    }
                    
                    let tetra_index = indicies[Int(tetra_id)]
                    let tetra = tetra_index.to_tetrahedra(positions: positions)
                    let tetra_bary = TetrahedraBarycentric(tetra)
                    
                    let int_point = simd_uint3(x: x, y: y, z: z)
                    let actual_p = deltas * simd_float3(int_point) + self.grid_bounds.min
                    
                    assert(tetra_bary.contains(actual_p))
                    
                    ret[x,y,z] = tetra_bary.interpolate(actual_p, data: tetra_index.lookup(list: data))
                }
            }
            print("At X: \(x)")
        }
        
        return ret
    }
}
