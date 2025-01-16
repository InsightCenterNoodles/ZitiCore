//
//  NoodlesComponent.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 9/13/24.
//

@MainActor
public protocol NoodlesComponent {
    func create(world: NoodlesWorld);
    func destroy(world: NoodlesWorld);
}
