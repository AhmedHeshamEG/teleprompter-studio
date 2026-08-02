import Foundation
import Network

/// Reads one HTTP request off a connection, hands it to `handler`, writes the response, then
/// closes (matches the `Connection: close` we advertise — this is a script-editing tool used by
/// one browser tab at a time on a LAN, not a long-lived API server, so we keep it simple).
final class LANConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private let handler: (HTTPRequest) async -> HTTPResponse

    init(connection: NWConnection, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection.cancel() }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let (request, _) = HTTPRequest.parse(buffer: self.buffer) {
                    self.respond(to: request)
                    return
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func respond(to request: HTTPRequest) {
        Task {
            let response = await handler(request)
            connection.send(content: response.serialize(), completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }
}
