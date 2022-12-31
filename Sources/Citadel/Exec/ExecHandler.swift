//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum SSHServerError: Error {
    case invalidCommand
    case invalidDataType
    case invalidChannelType
    case alreadyListening
    case notListening
}

final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    
    let delegate: ExecDelegate
    
    init(delegate: ExecDelegate, username: String?, id: UUID) {
        self.delegate = delegate
        self.username = username
        self.id = id
    }
    
    var context: ExecCommandContext?
    var pipeChannel: Channel?
    var environment: [String: String] = [:]
    let username: String?
    let id: UUID
    
    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        Task {
            try await self.context?.terminate()
            self.context = nil
            self.pipeChannel = nil
        }
        context.fireChannelInactive()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as SSHChannelRequestEvent.ExecRequest:
            self.exec(event, channel: context.channel)
        case let event as SSHChannelRequestEvent.EnvironmentRequest:
            Task {
                try await delegate.setEnvironmentValue(event.value, forKey: event.name)
            }
        case ChannelEvent.inputClosed:
            Task {
                try await self.context?.inputClosed()
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        
        guard case .byteBuffer(let bytes) = data.data else {
            fatalError("Unexpected read type")
        }
        
        guard case .channel = data.type else {
            context.fireErrorCaught(SSHServerError.invalidDataType)
            return
        }
        
        context.fireChannelRead(self.wrapInboundOut(bytes))
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
    
    private func exec(_ event: SSHChannelRequestEvent.ExecRequest, channel: Channel) {
        let successPromise = channel.eventLoop.makePromise(of: Int.self)
        let handler = ExecOutputHandler(username: username, remoteAddress: channel.remoteAddress, id: self.id) { code in
            successPromise.succeed(code)
        } onFailure: { _ in
            if event.wantReply {
                channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in
                    channel.close(promise: nil)
                }
            } else {
                channel.close(promise: nil)
            }
        }
        
        let (ours, theirs) = GlueHandler.matchedPair()
        
        // Ok, great, we've sorted stdout and stdin. For stderr we need a different strategy: we just park a thread for this.
        let stderrHandle = handler.stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { stderrHandle in
            do {
                guard let data = try stderrHandle.readToEnd() else {
                    stderrHandle.readabilityHandler = nil
                    return
                }
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeContiguousBytes(data)
                channel.write(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)), promise: nil)
            } catch {
                channel.close(promise: nil)
            }
        }
        
        channel.pipeline.addHandler(ours).flatMap {
            NIOPipeBootstrap(group: channel.eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { pipeChannel in
                    pipeChannel.pipeline.addHandlers(SSHInboundChannelDataWrapper(), theirs)
                }.withPipes(
                    inputDescriptor: dup(handler.stdoutPipe.fileHandleForReading.fileDescriptor),
                    outputDescriptor: dup(handler.stdinPipe.fileHandleForWriting.fileDescriptor)
                )
        }.flatMap { pipeChannel -> EventLoopFuture<Channel> in
            self.pipeChannel = pipeChannel
            let start = channel.eventLoop.makePromise(of: Void.self)
            start.completeWithTask {
                do {
                    self.context = try await self.delegate.start(
                        command: event.command,
                        outputHandler: handler
                    )
                } catch {
                    try await pipeChannel.close(mode: .all)
                }
            }
            
            return start.futureResult.flatMap {
                if event.wantReply {
                    return channel.triggerUserOutboundEvent(ChannelSuccessEvent()).map {
                        pipeChannel
                    }
                } else {
                    return channel.eventLoop.makeSucceededFuture(pipeChannel)
                }
            }
        }.flatMap { pipeChannel in
            successPromise.futureResult.flatMap { code in
                pipeChannel.close(mode: .all).map { code }
            }
        }.flatMap { code in
            channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: code))
        }.whenComplete { result in
            switch result {
            case .success:
                channel.close(promise: nil)
            case .failure:
                if event.wantReply {
                    channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in
                        channel.close(promise: nil)
                    }
                } else {
                    channel.close(promise: nil)
                }
            }
        }
    }
}
