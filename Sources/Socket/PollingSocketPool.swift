//
//  PollingSocketPool.swift
//  FlyingFox
//
//  Created by Simon Whitty on 13/02/2022.
//  Copyright © 2022 Simon Whitty. All rights reserved.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/swhitty/FlyingFox
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

final actor PollingSocketPool: AsyncSocketPool {

    enum Interval {
        case immediate
        case seconds(TimeInterval)

        static let `default` = Interval.seconds(0.1)
    }

    init(interval: Interval = .default) {
        self.interval = interval
    }

    func suspend(untilReady socket: Socket) async throws {
        try await withCancellingContinuation(returning: Void.self) { continuation, handler in
            let continuation = Continuation(continuation)
            appendContinuation(continuation, for: socket)
            handler.onCancel {
                self.removeContinuation(continuation, for: socket)
            }
        }
    }

    private let interval: Interval
    private var waiting: [Int32: Set<Continuation>] = [:]

    private func appendContinuation(_ continuation: Continuation, for socket: Socket) {
        guard state != .complete else {
            continuation.cancel()
            return
        }
        var existing = waiting[socket.file] ?? []
        existing.insert(continuation)
        waiting[socket.file] = existing
    }

    private func _removeContinuation(_ continuation: Continuation, for socket: Socket) {
        guard waiting[socket.file]?.contains(continuation) == true else { return }
        waiting[socket.file]?.remove(continuation)
        continuation.cancel()
    }

    // Careful not to escape non-isolated method
    // https://bugs.swift.org/browse/SR-15745
    nonisolated private func removeContinuation(_ continuation: Continuation, for socket: Socket) {
        Task { await _removeContinuation(continuation, for: socket) }
    }

    private var state: State = .ready

    private enum State {
        case ready
        case running
        case complete
    }

    func run() async throws {
        guard state != .running else { throw Error("Not Ready") }
        state = .running

        defer {
            for continuation in waiting.values.flatMap({ $0 }) {
                continuation.cancel()
            }
            waiting = [:]
            state = .complete
        }

        try await poll()
    }

    private func poll() async throws {
        repeat {
            try Task.checkCancellation()
            var buffer = waiting.keys.map {
                pollfd(fd: $0, events: Int16(POLLIN | POLLOUT), revents: 0)
            }

            Socket.poll(&buffer, nfds_t(buffer.count), interval.milliseconds)

            for file in buffer {
                if Socket.hasEvent(POLLIN, in: file.revents) || Socket.hasEvent(POLLOUT, in: file.revents) {
                    for continuation in waiting[file.fd]! {
                        continuation.resume()
                    }
                    waiting[file.fd] = nil
                }
            }

            await Task.yield()
        } while true
    }

    final class Continuation: Hashable {

        private let continuation: CheckedContinuation<Void, Swift.Error>

        init(_ continuation: CheckedContinuation<Void, Swift.Error>) {
            self.continuation = continuation
        }

        func resume() {
            continuation.resume()
        }

        func cancel() {
            continuation.resume(throwing: CancellationError())
        }

        func hash(into hasher: inout Hasher) {
            ObjectIdentifier(self).hash(into: &hasher)
        }

        static func == (lhs: Continuation, rhs: Continuation) -> Bool {
            lhs === rhs
        }
    }
}

extension PollingSocketPool.Interval {
    var milliseconds: Int32 {
        switch self {
        case .immediate:
            return 0
        case .seconds(let seconds):
            return Int32(seconds * 1000)
        }
    }
}


extension PollingSocketPool {

    struct Error: LocalizedError {
        var errorDescription: String?

        init(_ description: String) {
            self.errorDescription = description
        }
    }
}
