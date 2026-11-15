import Foundation

public struct AlvrTrackingTimeoutError: LocalizedError {
    public init() {}
    public var errorDescription: String? {
        "Quest reported StreamReady but sent no tracking timestamps; "
            + "keep the headset awake with ALVR in the foreground, then retry"
    }
}

/// Owns one headset session. Discovery offers endpoints only while waiting;
/// USB can retry its fixed endpoint without another beacon. All failures,
/// including missing tracking after StreamReady, follow the same retry path.
public actor HeadsetReconnectController {
    public struct Endpoint: Sendable {
        public let host: String
        public let protocolID: UInt64?
        public init(host: String, protocolID: UInt64? = nil) {
            self.host = host
            self.protocolID = protocolID
        }
    }

    public struct Connection: Sendable {
        public let refreshRate: Float
        public let close: @Sendable () -> Void
        public init(refreshRate: Float, close: @escaping @Sendable () -> Void) {
            self.refreshRate = refreshRate
            self.close = close
        }
    }

    public enum State: Equatable, Sendable { case waiting, connecting, connected, stopped }
    public private(set) var state: State = .waiting
    private let wired: Bool
    private let prepareWiredAttempt: @Sendable () async throws -> Void
    private let connect: @Sendable (Endpoint, Float, Bool, @escaping @Sendable () -> Void) async throws -> Connection
    private let sleep: @Sendable () async throws -> Void
    private let log: @Sendable (String) -> Void
    private var refreshRate: Float
    private var hasConnected = false
    private var attemptID: UUID?
    private var attemptDisconnected = false
    private var connection: Connection?
    private var worker: Task<Void, Never>?
    private var lastFailure: String?
    private var repeatedFailures = 0

    public init(wired: Bool, refreshRate: Float,
                prepareWiredAttempt: @escaping @Sendable () async throws -> Void = {},
                connect: @escaping @Sendable (Endpoint, Float, Bool, @escaping @Sendable () -> Void) async throws -> Connection,
                sleep: @escaping @Sendable () async throws -> Void = {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.wired = wired
        self.prepareWiredAttempt = prepareWiredAttempt
        self.refreshRate = refreshRate
        self.connect = connect
        self.sleep = sleep
        self.log = log
    }

    /// Retains the existing bounded USB startup failure behaviour.
    public func connectInitially(_ endpoint: Endpoint) async throws {
        guard state == .waiting else { return }
        try await run(endpoint, maximumAttempts: 10)
    }

    public func offer(_ endpoint: Endpoint) {
        guard state == .waiting else { return }
        state = .connecting
        worker = Task {
            try? await self.run(endpoint, maximumAttempts: self.wired ? nil : 1)
        }
    }

    public func shutdown() {
        state = .stopped
        attemptID = nil
        worker?.cancel()
        worker = nil
        connection?.close()
        connection = nil
    }

    private func disconnected(_ id: UUID, endpoint: Endpoint) {
        guard state != .stopped, attemptID == id, !attemptDisconnected else { return }
        attemptDisconnected = true
        guard state == .connected else { return }
        connection?.close()
        connection = nil
        state = .waiting
        log("Headset disconnected; waiting for it to reconnect…")
        if wired { offer(endpoint) }
    }

    private func run(_ endpoint: Endpoint, maximumAttempts: Int?) async throws {
        var attempts = 0
        while state != .stopped, !Task.isCancelled {
            state = .connecting
            let id = UUID()
            attemptID = id
            attemptDisconnected = false
            attempts += 1
            do {
                if wired { try await prepareWiredAttempt() }
                try Task.checkCancellation()
                guard state != .stopped else { return }
                let result = try await connect(endpoint, refreshRate, hasConnected) {
                    Task { await self.disconnected(id, endpoint: endpoint) }
                }
                guard state != .stopped, !Task.isCancelled,
                      !attemptDisconnected else {
                    result.close()
                    throw CancellationError()
                }
                connection = result
                state = .connected
                refreshRate = result.refreshRate
                if hasConnected { log("Headset reconnected") }
                hasConnected = true
                lastFailure = nil
                repeatedFailures = 0
                return
            } catch {
                guard state != .stopped, !Task.isCancelled else { return }
                // Retries come once a second. Log a failure when it changes,
                // then only every tenth repeat, so one cause is one line.
                let failure = error.localizedDescription
                if failure == lastFailure {
                    repeatedFailures += 1
                    if repeatedFailures % 10 == 0 {
                        log("ALVR handshake still failing after \(repeatedFailures + 1) attempts: \(failure)")
                    }
                } else {
                    lastFailure = failure
                    repeatedFailures = 0
                    log("ALVR handshake failed: \(failure)")
                }
                if let maximumAttempts, attempts >= maximumAttempts {
                    state = .waiting
                    throw error
                }
                do { try await sleep() }
                catch {
                    if state != .stopped { state = .waiting }
                    return
                }
            }
        }
    }
}
