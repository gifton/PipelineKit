//
//  LoggingEventBridge.swift
//  PipelineKit
//
//  Bridge to make LoggingEmitter work as an EventSubscriber
//

import Foundation

/// Bridges LoggingEmitter to work as an EventSubscriber.
public final class LoggingEventBridge: EventSubscriber {
    private let emitter: LoggingEmitter
    
    public init(emitter: LoggingEmitter) {
        self.emitter = emitter
    }
    
    public func process(_ event: PipelineEvent) async {
        // LoggingEmitter.emit is synchronous, so we just call it
        emitter.emit(event)
    }
}