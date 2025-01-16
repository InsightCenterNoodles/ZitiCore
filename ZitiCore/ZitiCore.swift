//
//  ZitiCore.swift
//  ZitiCore
//
//  Created by Nicholas Brunhart-Lupo on 1/14/25.
//

import Foundation

public func initialize_ziti_core() {
    ParticleAdvectionComponent.registerComponent()
    AdvectionSpawnComponent.registerComponent()
    AdvectionSystem.registerSystem()
    AdvectionSpawnSystem.registerSystem()
}
