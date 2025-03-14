//
//  Communication.swift
//  Ziti
//
//  Created by Nicholas Brunhart-Lupo on 2/13/24.
//

import Foundation
import SwiftUI
import SwiftCBOR
import RealityKit
import Starscream

enum ConnectionState {
    case connected
    case connecting
    case disconnected
    case reconnecting
}

public class NoodlesCommunicator {
    var url: URL
    var socket : WebSocket!
    var queue = DispatchQueue(label: "gov.nrel.noodles.ziti")
    var decoder : MessageDecoder
    public var world : NoodlesWorld
    
    private var connection_state: ConnectionState = .disconnected
    private var reconnect_attempts : Int = 0
    private var max_reconnect_attempts : Int = 8
    private var base_reconnect_delay : TimeInterval = 5
    
    private var message_stream: AsyncStream<[FromServerMessage]>!
    private var continuation: AsyncStream<[FromServerMessage]>.Continuation?

    public init(url: URL, world : NoodlesWorld) {
        print("Starting connection to \(url.host() ?? "UNKNOWN") at \(url.port ?? 50000)")
        
        self.url = url
        decoder = MessageDecoder(current_host: url.host()!)
        self.world = world
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        socket = WebSocket(request: request)
        socket.callbackQueue = queue
        socket.onEvent = self.on_recv_cb
        
        
        let (stream, continuation) = AsyncStream<[FromServerMessage]>.makeStream()
        self.message_stream = stream
        self.continuation = continuation
        
        Task(priority: TaskPriority.userInitiated) {
            for await messages in message_stream {
                await self.handle_messages(mlist: messages)
            }
        }
        
        socket.connect()
        
    }
    
    public func connect() {
        guard connection_state == .disconnected || connection_state == .reconnecting else { return }
        connection_state = .connecting
        print("Opening socket...")
        socket.connect()
    }
    
    public func disconnect() {
        connection_state = .disconnected
        print("Closing socket...")
        socket.disconnect()
    }
    
    public func send<T : NoodlesMessage>(msg: T) {
        let content = msg.to_cbor()
        let packet = CBOR.array([CBOR.unsignedInt(UInt64(T.message_id)), content]).encode()
        socket.write(data: Data(packet))
    }
    
    func on_message(msg: Result<URLSessionWebSocketTask.Message, Error>) {
        switch msg {
        case .success(let m):
            switch m {
            case .data(let d):
                on_message_data(data: d)
            case .string(let s):
                print("Recv text from server: \(s)")
            default:
                break
            }
            break
        case .failure(let err):
            handle_ws_error(err)
        }
    }
    
    func on_message_data(data: Data) {
        // we handle decoding in this thread to avoid creating lots of small tasks.
        // normally this decode is quick
        let slice = data.withUnsafeBytes { ArraySlice($0) }
        let messages = decoder.decode(bytes: slice)
        
        // If this is slow, we can use AsyncStream. Seems to be fairly efficient right now.
        //DispatchQueue.main.async(group: nil, qos: DispatchQoS.userInteractive, flags: []) {
        //    self.handle_messages(mlist: messages)
        //}
        
        continuation?.yield(messages)
    }
    
    func handle_ws_error(_ error: Error?) {
        if let e = error as? WSError {
            print("websocket encountered an error: \(e.message)")
        } else if let e = error {
            print("websocket encountered an error: \(e.localizedDescription)")
        } else {
            print("websocket encountered an error")
        }
        
        handle_abnormal_disconnection(code: CloseCode.protocolError.rawValue)
    }
    
    func show_error_message() {
        DispatchQueue.main.async {
            self.world.root_entity.isEnabled = false
            self.world.error_entity.isEnabled = true
        }
    }
    
    func show_content() {
        DispatchQueue.main.async {
            self.world.root_entity.isEnabled = true
            self.world.error_entity.isEnabled = false
        }
    }
    
    func handle_abnormal_disconnection(code: UInt16) {
        print("Abnormal socket termination.")
        connection_state = .disconnected
        socket.disconnect(closeCode: code)
        attempt_reconnect()
    }
    
    func attempt_reconnect() {
        print("Attempting to reconnect")
        show_error_message()
        
        guard reconnect_attempts < max_reconnect_attempts else {
            print("Reached maximum reconnect attempts. Stopping.");
            return;
        }
        
        reconnect_attempts += 1
        
        let delay = base_reconnect_delay * pow( 2.0, Double(reconnect_attempts) )
        
        print("Reconnecting in \(delay) seconds...")
        
        connection_state = .reconnecting
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.connect()
        }
    }
    
    func on_recv_cb(event: Starscream.WebSocketEvent) {
        switch event {
        case .connected(let headers):
            connection_state = .connected
            reconnect_attempts = 0
            show_content()
            print("websocket is connected: \(headers)")
            self.send(msg: IntroductionMessage(client_name: "Swift Client"))
            
        case .disconnected(let reason, let code):
            print("websocket is disconnected: \(reason) with code: \(code)")
            if code != 1000 {
                handle_abnormal_disconnection(code: CloseCode.goingAway.rawValue)
            }
            
            
        case .text(let string):
            print("Received text: \(string)")
            
        case .binary(let data):
            on_message_data(data: data)
            
        case .ping(let content):
            socket.write(pong: content ?? Data())
            
        case .pong(_):
            break
            
        case .viabilityChanged(let viable):
            if !viable {
                handle_abnormal_disconnection(code: CloseCode.goingAway.rawValue)
            }
            break
            
        case .reconnectSuggested(let suggestion):
            if suggestion {
                handle_abnormal_disconnection(code: CloseCode.goingAway.rawValue)
            }
            break
            
        case .cancelled:
            print("Socket cancelled.")
            handle_abnormal_disconnection(code: CloseCode.goingAway.rawValue)
            break
            
        case .error(let error):
            handle_ws_error(error)
            
        case .peerClosed:
            handle_abnormal_disconnection(code: CloseCode.goingAway.rawValue)
        }
    }
    
    @MainActor
    func handle_messages(mlist : [FromServerMessage]) {
        //capture_bounds.begin()
        
        for m in mlist {
            //dump(m)
            world.handle_message(m)
        }
        
        //capture_bounds.end()
    }
    
    @MainActor
    public func invoke_method(method: NooID, context: InvokeMessageOn, args: [CBOR], on_done: @escaping (MsgMethodReply) -> ()) {
        world.invoke_method(method: method, context: context, args: args, on_done: on_done)
    }
}
