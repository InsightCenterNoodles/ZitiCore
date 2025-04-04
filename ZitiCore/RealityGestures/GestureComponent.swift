/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A component that handles standard drag, rotate, and scale gestures for an entity.
*/

/*
 Modified by Nicholas Brunhart-Lupo for Ziti.
 */

import RealityKit
import SwiftUI

public class EntityGestureState {
    
    /// The entity currently being dragged if a gesture is in progress.
    var targetedEntity: Entity?
    
    // MARK: - Drag
    
    /// The starting position.
    var dragStartPosition: SIMD3<Float> = .zero
    
    /// Marks whether the app is currently handling a drag gesture.
    var isDragging = false
    
    /// When `rotateOnDrag` is`true`, this entity acts as the pivot point for the drag.
    var pivotEntity: Entity?
    
    var initialOrientation: simd_quatf?
    
    // MARK: - Magnify
    
    /// The starting scale value.
    var startScale: SIMD3<Float> = .one
    
    /// Marks whether the app is currently handling a scale gesture.
    var isScaling = false
    
    // MARK: - Rotation
    
    /// The starting rotation value.
    var startOrientation = Rotation3D.identity
    
    /// Marks whether the app is currently handling a rotation gesture.
    var isRotating = false
    
    // MARK: - Tap
    
    var isTapping = false
    
    // MARK: - Singleton Accessor
    
    /// Retrieves the shared instance.
    static let shared = EntityGestureState()
}

// MARK: -

/// A component that handles gesture logic for an entity.
@MainActor
public struct GestureComponent: Component, Codable {
    
    /// Instead of changing the transform of the entity this component is attached to, delegate to the parent instead (MODIFICATION)
    public var delegateToParent: Bool = false
    
    /// A Boolean value that indicates whether a gesture can drag the entity.
    public var canDrag: Bool = true
    
    /// A Boolean value that indicates whether a dragging can move the object in an arc, similar to dragging windows or moving the keyboard.
    public var pivotOnDrag: Bool = true
    
    /// A Boolean value that indicates whether a pivot drag keeps the orientation toward the
    /// viewer throughout the drag gesture.
    ///
    /// The property only applies when `pivotOnDrag` is `true`.
    public var preserveOrientationOnPivotDrag: Bool = true
    
    /// A Boolean value that indicates whether a gesture can scale the entity.
    public var canScale: Bool = true
    
    /// A Boolean value that indicates whether a gesture can rotate the entity.
    public var canRotate: Bool = true
    
    /// Force rotation to be around the up axis only
    public var lockRotateUpAxis: Bool = false
    
    /// Disable scaling while using the pinch gesture
    public var lockScale: Bool = false
    
    public var canTap: Bool = true
    
    // MARK: - Drag Logic
    
    /// Handle `.onChanged` actions for drag gestures.
    mutating func onChanged(value: EntityTargetValue<DragGesture.Value>) {
        guard canDrag else { return }
        
        let state = EntityGestureState.shared
        
        // Only allow a single Entity to be targeted at any given time.
        if state.targetedEntity == nil {
            guard let tgt = delegateToParent ? value.entity.parent : value.entity else {
                return
            }
            state.targetedEntity = tgt
            state.initialOrientation = tgt.orientation(relativeTo: nil)
        }
        
        //print("START TRANSFORM")
        //dump(state.targetedEntity?.transform)
        
        
        if pivotOnDrag {
            handlePivotDrag(value: value)
        } else {
            handleFixedDrag(value: value)
        }
        
        update_noodles()
    }
    
    mutating private func handlePivotDrag(value: EntityTargetValue<DragGesture.Value>) {
        
        let state = EntityGestureState.shared
        guard let entity = state.targetedEntity else { fatalError("Gesture contained no entity") }
        
        // The transform that the pivot will be moved to.
        var targetPivotTransform = Transform()
        
        // Set the target pivot transform depending on the input source.
        if let inputDevicePose = value.inputDevicePose3D {
            
            // If there is an input device pose, use it for positioning and rotating the pivot.
            targetPivotTransform.scale = .one
            targetPivotTransform.translation = value.convert(inputDevicePose.position, from: .local, to: .scene)
            targetPivotTransform.rotation = value.convert(AffineTransform3D(rotation: inputDevicePose.rotation), from: .local, to: .scene).rotation
        } else {
            // If there is not an input device pose, use the location of the drag for positioning the pivot.
            targetPivotTransform.translation = value.convert(value.location3D, from: .local, to: .scene)
        }
        
        if !state.isDragging {
            // If this drag just started, create the pivot entity.
            let pivotEntity = Entity()
            
            guard let parent = entity.parent else { fatalError("Non-root entity is missing a parent.") }
            
            // Add the pivot entity into the scene.
            parent.addChild(pivotEntity)
            
            // Move the pivot entity to the target transform.
            pivotEntity.move(to: targetPivotTransform, relativeTo: nil)
            
            // Add the targeted entity as a child of the pivot without changing the targeted entity's world transform.
            pivotEntity.addChild(entity, preservingWorldTransform: true)
            
            // Store the pivot entity.
            state.pivotEntity = pivotEntity
            
            // Indicate that a drag has started.
            state.isDragging = true

        } else {
            // If this drag is ongoing, move the pivot entity to the target transform.
            // The animation duration smooths the noise in the target transform across frames.
            state.pivotEntity?.move(to: targetPivotTransform, relativeTo: nil, duration: 0.2)
        }
        
        if preserveOrientationOnPivotDrag, let initialOrientation = state.initialOrientation {
            state.targetedEntity?.setOrientation(initialOrientation, relativeTo: nil)
        }
    }
    
    mutating private func handleFixedDrag(value: EntityTargetValue<DragGesture.Value>) {
        let state = EntityGestureState.shared
        guard let entity = state.targetedEntity else { fatalError("Gesture contained no entity") }
        
        if !state.isDragging {
            state.isDragging = true
            state.dragStartPosition = entity.scenePosition
        }
   
        let translation3D = value.convert(value.gestureValue.translation3D, from: .local, to: .scene)
        
        let offset = SIMD3<Float>(x: Float(translation3D.x),
                                  y: Float(translation3D.y),
                                  z: Float(translation3D.z))
        
        entity.scenePosition = state.dragStartPosition + offset
        if let initialOrientation = state.initialOrientation {
            state.targetedEntity?.setOrientation(initialOrientation, relativeTo: nil)
        }
        
    }
    
    /// Handle `.onEnded` actions for drag gestures.
    mutating func onEnded(value: EntityTargetValue<DragGesture.Value>) {
        let state = EntityGestureState.shared
        state.isDragging = false
        
        if let pivotEntity = state.pivotEntity,
           pivotOnDrag {
            pivotEntity.parent!.addChild(state.targetedEntity!, preservingWorldTransform: true)
            pivotEntity.removeFromParent()
        }
        
        final_transform_change_check()
        
        state.pivotEntity = nil
        state.targetedEntity = nil
    }

    // MARK: - Magnify (Scale) Logic
    
    /// Handle `.onChanged` actions for magnify (scale)  gestures.
    mutating func onChanged(value: EntityTargetValue<MagnifyGesture.Value>) {
        let state = EntityGestureState.shared
        guard canScale, !state.isDragging else { return }
        
        guard let entity = delegateToParent ? value.entity.parent : value.entity else {
            return
        }
        
        if !state.isScaling {
            state.isScaling = true
            state.startScale = entity.scale
        }
        
        let magnification = Float(value.magnification)
        entity.scale = state.startScale * magnification
        update_noodles()
    }
    
    /// Handle `.onEnded` actions for magnify (scale)  gestures
    mutating func onEnded(value: EntityTargetValue<MagnifyGesture.Value>) {
        final_transform_change_check()
        EntityGestureState.shared.isScaling = false
    }
    
    // MARK: - Rotate Logic
    
    /// Handle `.onChanged` actions for rotate  gestures.
    mutating func onChanged(value: EntityTargetValue<RotateGesture3D.Value>) {
        let state = EntityGestureState.shared
        guard canRotate, !state.isDragging else { return }

        guard let entity = delegateToParent ? value.entity.parent : value.entity else {
            return
        }
        
        if !state.isRotating {
            state.isRotating = true
            state.startOrientation = .init(entity.orientation(relativeTo: nil))
        }
        
        let rotation = value.rotation
        let flippedRotation = Rotation3D(angle: rotation.angle,
                                         axis: RotationAxis3D(x: -rotation.axis.x,
                                                              y: rotation.axis.y,
                                                              z: -rotation.axis.z))
        var newOrientation = state.startOrientation.rotated(by: flippedRotation)
        
        if lockRotateUpAxis {
            
            let forward = newOrientation.quaternion.act(simd_double3(0,0,-1))
            
            let flatForward = simd_double3(forward.x, 0, forward.z)
            
            let newRotation = simd_quatd(from: simd_double3(0,0,-1), to: flatForward)
            
            newOrientation = .init(newRotation)
        }
        
        entity.setOrientation(.init(newOrientation), relativeTo: nil)
        update_noodles()
    }
    
    /// Handle `.onChanged` actions for rotate  gestures.
    mutating func onEnded(value: EntityTargetValue<RotateGesture3D.Value>) {
        final_transform_change_check()
        EntityGestureState.shared.isRotating = false
    }
    
    // MARK: - Tap Logic
    
    /// Handle `.onChanged` actions for tap  gestures.
    mutating func onChanged(value: EntityTargetValue<SpatialTapGesture.Value>) {
        // we never actually seem to get here. probably being confused with another gesture?
    }
    
    /// Handle `.onChanged` actions for tap  gestures.
    mutating func onEnded(value: EntityTargetValue<SpatialTapGesture.Value>) {
        // we DEFINITELY get here when taps are done
        
        print("handling click")
        guard let support = value.entity.components[GestureSupportComponent.self] else {
            return
        }
        
        print("sending click")
        
        support.world?.invoke_method_by_name(method_name: CommonStrings.activate, context: .Entity(support.noo_id), args: [])
    }
    
    // MARK: Customization of Gesture Support for Ziti
    
    func update_noodles() {
        guard let e = EntityGestureState.shared.targetedEntity else {
            return
        }
        e.components[GestureSupportComponent.self]?.fire(e: e)
        
    }
    
    func final_transform_change_check() {
        guard let e = EntityGestureState.shared.targetedEntity else {
            return
        }
        default_log.info(">>> final transform change check")
        e.components[GestureSupportComponent.self]?.complete(e: e)
    }
}

private func preserve_yaw_only(from matrix: simd_float4x4) -> simd_float4x4 {
    // Extract the forward vector (Z-axis of the QR code)
    let forward = simd_normalize(simd_float3(matrix.columns.2.x, 0, matrix.columns.2.z))
    
    // Extract right vector (X-axis) perpendicular to forward
    let right = simd_cross(simd_float3(0, 1, 0), forward)
    
    // Y-axis remains the world up direction (0,1,0)
    let up = simd_float3(0, 1, 0)
    
    // Construct the new rotation matrix
    var ret = matrix
    ret.columns.0 = simd_float4(right, 0)  // X-axis
    ret.columns.1 = simd_float4(up, 0)     // Y-axis (remains unchanged)
    ret.columns.2 = simd_float4(forward, 0) // Z-axis (flattened to horizontal)
    
    return ret
}

// MARK: Customizations for Ziti
struct GestureSupportComponent : Component {
    weak var world: NoodlesWorld?
    var noo_id: NooID
    
    var last_t: SIMD3<Float> = .zero
    var last_r: simd_quatf = simd_quatf(ix: 0.0, iy: 0.0, iz: 0.0, r: 1.0)
    var last_s: SIMD3<Float> = .one
    
    var pending_transform: simd_float4x4?
    
    @MainActor
    mutating func fire(e: Entity) {
        //print("Updating remote transforms for entity")
        guard let world else { return }
        
        let n_t = e.transform.translation
        let n_r = e.transform.rotation
        let n_s = e.transform.scale
        
        if n_t != last_t {
            //print("sending translation ", n_t)
            world.invoke_method_by_name(
                method_name: CommonStrings.set_position,
                context: .Entity(noo_id),
                args: [[n_t.x.toCBOR(), n_t.y.toCBOR(), n_t.z.toCBOR()].toCBOR()]
            )
            last_t = n_t
        }
        
        if n_r != last_r {
            //print("sending rotation ", n_r)
            let as_vec = n_r.vector;
            world.invoke_method_by_name(
                method_name: CommonStrings.set_rotation,
                context: .Entity(noo_id),
                args: [[as_vec.x.toCBOR(), as_vec.y.toCBOR(), as_vec.z.toCBOR(), as_vec.w.toCBOR()].toCBOR()]
            )
            last_r = n_r
        }
        
        if n_s != last_s {
            //print("sending scale ", n_s)
            world.invoke_method_by_name(
                method_name: CommonStrings.set_scale,
                context: .Entity(noo_id),
                args: [[n_s.x.toCBOR(), n_s.y.toCBOR(), n_s.z.toCBOR()].toCBOR()]
                // TODO: maybe add change rejection handling
            )
            last_s = n_s
        }
    }
    
    func complete(e: Entity) {
        //print("Checking if entity has server-mandated transform")
        guard let tf = pending_transform else { return }
        
        //print("Setting transform")
        default_log.info(">>> final transform update")
        e.move(to: tf, relativeTo: e.parent, duration: 0.1)
    }
}




