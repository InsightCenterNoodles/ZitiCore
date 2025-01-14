//
//  Cube.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 7/16/24.
//

import Foundation
import RealityFoundation

private let CUBE_POS : [SIMD3<Float>] = [
    [ -1.0, -1.0,  1.0 ],
    [  1.0, -1.0,  1.0 ],
    [  1.0,  1.0,  1.0 ],
    [ -1.0,  1.0,  1.0 ],
    
    [ -1.0, -1.0, -1.0 ],
    [  1.0, -1.0, -1.0 ],
    [  1.0,  1.0, -1.0 ],
    [ -1.0,  1.0, -1.0 ],
];

private let CUBE_NOR : [SIMD3<Float>] = [
    [ -0.5774, -0.5774, 0.5774 ],
    [  0.5774, -0.5774, 0.5774 ],
    [  0.5774,  0.5774, 0.5774 ],
    [ -0.5774,  0.5774, 0.5774 ],
    
    [ -0.5774, -0.5774, -0.5774 ],
    [  0.5774, -0.5774, -0.5774 ],
    [  0.5774,  0.5774, -0.5774 ],
    [ -0.5774,  0.5774, -0.5774 ],
];

private let CUBE_INDEX : [UInt16] = [
    // front
    0, 1, 2,
    2, 3, 0,
    // right
    1, 5, 6,
    6, 2, 1,
    // back
    7, 6, 5,
    5, 4, 7,
    // left
    4, 0, 3,
    3, 7, 4,
    // bottom
    4, 5, 1,
    1, 0, 4,
    // top
    3, 2, 6,
    6, 7, 3,
];

func shape_cube() -> ([SIMD3<Float>], [SIMD3<Float>], [UInt16], BoundingBox) {
    return (CUBE_POS, CUBE_NOR, CUBE_INDEX, BoundingBox(min: [-1, -1, -1], max: [1,1,1]))
}
