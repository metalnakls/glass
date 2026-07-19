import Foundation
import Testing
@testable import GlassRemoteCore

@Suite("TransmissionRPCClient", .serialized)
struct TransmissionRPCClientTests {
    @Test("retries once after HTTP 409 with session header")
    func retriesAfter409() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 409,
                headers: ["X-Transmission-Session-Id": "abc123"],
                body: #"{"result":"success","arguments":{}}"#
            ),
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"downloadSpeed":1,"uploadSpeed":2}}"#
            )
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        let stats = try await client.fetchSessionStats()

        #expect(stats.downloadSpeed == 1)
        #expect(stats.uploadSpeed == 2)
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests.last?.value(forHTTPHeaderField: "X-Transmission-Session-Id") == "abc123")
    }

    @Test("adds basic authorization header")
    func setsBasicAuthHeader() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"downloadSpeed":0,"uploadSpeed":0}}"#
            )
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        _ = try await client.fetchSessionStats()

        let request = try #require(transport.recordedRequests.first)
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("Basic "))
    }

    @Test("uses credentials embedded in the RPC URL")
    func usesURLCredentials() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"downloadSpeed":0,"uploadSpeed":0}}"#
            )
        ])
        let config = TransmissionRPCConfig(
            profile: RemoteProfile(
                name: "Router",
                rpcURL: URL(string: "http://admin:Transmissus@localhost:9091/transmission/rpc")!,
                username: ""
            ),
            password: ""
        )

        let client = TransmissionRPCClient(config: config, session: transport.session)
        _ = try await client.fetchSessionStats()

        let request = try #require(transport.recordedRequests.first)
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let encoded = String(auth.dropFirst("Basic ".count))
        let decoded = try #require(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
        #expect(decoded == "admin:Transmissus")
    }

    @Test("maps non-success HTTP responses")
    func mapsHTTPError() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(status: 403, headers: [:], body: "denied")
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)

        await #expect(throws: TransmissionRPCError.self) {
            _ = try await client.fetchSessionStats()
        }
    }

    @Test("maps transport failures to endpoint-specific network errors")
    func mapsNetworkError() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .failure(.cannotConnectToHost)
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)

        do {
            _ = try await client.fetchSessionStats()
            #expect(Bool(false))
        } catch let error as TransmissionRPCError {
            guard case let .network(url, message) = error else {
                #expect(Bool(false))
                return
            }
            #expect(url == "http://localhost:9091/transmission/rpc")
            #expect(!message.isEmpty)
            #expect(error.localizedDescription.contains("Could not reach"))
        }
    }

    @Test("passes file selection when adding torrent metainfo")
    func passesFileSelectionOnAdd() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#)
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        try await client.addTorrentFile(
            data: Data([0x01, 0x02]),
            downloadDirectory: "/downloads",
            fileSelection: TorrentAddFileSelection(
                filesUnwanted: [1, 3],
                priorityHigh: [0],
                priorityLow: [2]
            )
        )

        let body = try #require(transport.recordedRequestBodies.first ?? nil)
        let rpcRequest = try JSONDecoder().decode(RecordedRPCRequest.self, from: body)

        #expect(rpcRequest.method == "torrent-add")
        #expect(rpcRequest.arguments["metainfo"] == .string("AQI="))
        #expect(rpcRequest.arguments["download-dir"] == .string("/downloads"))
        #expect(rpcRequest.arguments["files-unwanted"] == .array([.int(1), .int(3)]))
        #expect(rpcRequest.arguments["priority-high"] == .array([.int(0)]))
        #expect(rpcRequest.arguments["priority-low"] == .array([.int(2)]))
    }

    @Test("renames a newly added torrent when a custom name is supplied")
    func renamesNewTorrentOnAdd() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"torrent-added":{"id":7,"name":"Original","hashString":"abc123"}}}"#
            ),
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#)
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        try await client.addTorrentFile(
            data: Data([0x01]),
            torrentName: "Custom Name",
            downloadDirectory: nil
        )

        let requests = try transport.recordedRequestBodies.map { body in
            try JSONDecoder().decode(RecordedRPCRequest.self, from: #require(body))
        }
        #expect(requests.map(\.method) == ["torrent-add", "torrent-rename-path"])
        #expect(requests[1].arguments["ids"] == .array([.string("abc123")]))
        #expect(requests[1].arguments["path"] == .string("Original"))
        #expect(requests[1].arguments["name"] == .string("Custom Name"))
    }

    @Test("renames a duplicate only when a custom name is supplied")
    func renamesDuplicateOnAdd() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"torrent-duplicate":{"id":7,"name":"Original","hashString":"abc123"}}}"#
            ),
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#)
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        try await client.addTorrentFile(
            data: Data([0x01]),
            torrentName: "Custom Name",
            downloadDirectory: nil
        )

        let requests = try transport.recordedRequestBodies.map { body in
            try JSONDecoder().decode(RecordedRPCRequest.self, from: #require(body))
        }
        #expect(requests.map(\.method) == ["torrent-add", "torrent-rename-path"])
    }

    @Test("fetches free space for a path")
    func fetchesFreeSpace() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"path":"/downloads","size-bytes":1073741824,"total-size":2147483648}}"#
            )
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        let freeSpace = try await client.fetchFreeSpace(at: "/downloads")

        #expect(freeSpace.path == "/downloads")
        #expect(freeSpace.availableBytes == 1_073_741_824)
        #expect(freeSpace.totalSize == 2_147_483_648)

        let body = try #require(transport.recordedRequestBodies.first ?? nil)
        let rpcRequest = try JSONDecoder().decode(RecordedRPCRequest.self, from: body)
        #expect(rpcRequest.method == "free_space")
        #expect(rpcRequest.arguments["path"] == .string("/downloads"))
    }

    @Test("uses deprecated session free space when available")
    func usesDeprecatedSessionFreeSpace() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"download-dir":"/downloads","download-dir-free-space":536870912}}"#
            )
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        let freeSpace = try #require(try await client.fetchDefaultFreeSpace())

        #expect(freeSpace.path == "/downloads")
        #expect(freeSpace.availableBytes == 536_870_912)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("queue move calls send expected RPC methods and ids")
    func sendsQueueMoveRequests() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#),
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#),
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#),
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#)
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        try await client.queueMoveTop(ids: ["abc", "def"])
        try await client.queueMoveUp(ids: ["abc", "def"])
        try await client.queueMoveDown(ids: ["abc", "def"])
        try await client.queueMoveBottom(ids: ["abc", "def"])

        let requests = try transport.recordedRequestBodies.map { body in
            try JSONDecoder().decode(RecordedRPCRequest.self, from: #require(body))
        }

        #expect(requests.map(\.method) == [
            "queue-move-top",
            "queue-move-up",
            "queue-move-down",
            "queue-move-bottom"
        ])
        for request in requests {
            #expect(request.arguments["ids"] == .array([.string("abc"), .string("def")]))
        }
    }

    @Test("torrent summary request includes queue and metadata progress")
    func fetchTorrentsRequestsQueueAndMetadataProgress() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{"torrents":[]}}"#)
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        _ = try await client.fetchTorrents()

        let body = try #require(transport.recordedRequestBodies.first ?? nil)
        let rpcRequest = try JSONDecoder().decode(RecordedRPCRequest.self, from: body)
        let fields = try #require(rpcRequest.arguments["fields"])

        #expect(rpcRequest.method == "torrent-get")
        guard case let .array(values) = fields else {
            #expect(Bool(false))
            return
        }
        #expect(values.contains(.string("queuePosition")))
        #expect(values.contains(.string("metadataPercentComplete")))
    }

    @Test("decodes session settings")
    func decodesSessionSettings() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 200,
                headers: [:],
                body: """
                {"result":"success","arguments":{
                    "version":"4.0.6",
                    "rpc-version":17,
                    "download-dir":"/downloads",
                    "incomplete-dir":"/incomplete",
                    "incomplete-dir-enabled":true,
                    "speed-limit-down":1200,
                    "speed-limit-down-enabled":false,
                    "speed-limit-up":300,
                    "speed-limit-up-enabled":true,
                    "alt-speed-enabled":true,
                    "alt-speed-down":100,
                    "alt-speed-up":40,
                    "seedRatioLimit":2.5,
                    "seedRatioLimited":true,
                    "download-queue-enabled":true,
                    "download-queue-size":5,
                    "seed-queue-enabled":false,
                    "seed-queue-size":10,
                    "queue-stalled-enabled":true,
                    "queue-stalled-minutes":30,
                    "peer-limit-global":200,
                    "peer-limit-per-torrent":60,
                    "peer-port":51413,
                    "pex-enabled":true,
                    "dht-enabled":true,
                    "lpd-enabled":false,
                    "utp-enabled":true,
                    "encryption":"preferred",
                    "blocklist-enabled":true,
                    "blocklist-url":"https://example.com/blocklist",
                    "blocklist-size":123
                }}
                """
            )
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        let settings = try await client.fetchSessionSettings()

        #expect(settings.version == "4.0.6")
        #expect(settings.rpcVersion == 17)
        #expect(settings.downloadDirectory == "/downloads")
        #expect(settings.incompleteDirectory == "/incomplete")
        #expect(settings.incompleteDirectoryEnabled == true)
        #expect(settings.downloadSpeedLimit == 1200)
        #expect(settings.downloadSpeedLimited == false)
        #expect(settings.uploadSpeedLimit == 300)
        #expect(settings.uploadSpeedLimited == true)
        #expect(settings.alternativeSpeedEnabled == true)
        #expect(settings.alternativeDownloadSpeedLimit == 100)
        #expect(settings.alternativeUploadSpeedLimit == 40)
        #expect(settings.seedRatioLimit == 2.5)
        #expect(settings.seedRatioLimited == true)
        #expect(settings.downloadQueueEnabled == true)
        #expect(settings.downloadQueueSize == 5)
        #expect(settings.seedQueueEnabled == false)
        #expect(settings.seedQueueSize == 10)
        #expect(settings.queueStalledEnabled == true)
        #expect(settings.queueStalledMinutes == 30)
        #expect(settings.globalPeerLimit == 200)
        #expect(settings.torrentPeerLimit == 60)
        #expect(settings.peerPort == 51413)
        #expect(settings.pexEnabled == true)
        #expect(settings.dhtEnabled == true)
        #expect(settings.lpdEnabled == false)
        #expect(settings.utpEnabled == true)
        #expect(settings.encryption == "preferred")
        #expect(settings.blocklistEnabled == true)
        #expect(settings.blocklistURL == "https://example.com/blocklist")
        #expect(settings.blocklistSize == 123)

        let body = try #require(transport.recordedRequestBodies.first ?? nil)
        let rpcRequest = try JSONDecoder().decode(RecordedRPCRequest.self, from: body)
        #expect(rpcRequest.method == "session-get")
        guard case let .array(fields) = try #require(rpcRequest.arguments["fields"]) else {
            #expect(Bool(false))
            return
        }
        #expect(fields.contains(.string("download-dir")))
        #expect(fields.contains(.string("queue-stalled-minutes")))
        #expect(fields.contains(.string("blocklist-size")))
    }

    @Test("session settings patch sends only changed keys")
    func sessionSettingsPatchSendsOnlyChangedKeys() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(status: 200, headers: [:], body: #"{"result":"success","arguments":{}}"#)
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        try await client.setSessionSettings(
            TransmissionSessionSettingsPatch(
                downloadDirectory: "/new",
                downloadSpeedLimited: false,
                seedRatioLimit: 2.25,
                pexEnabled: true
            )
        )

        let body = try #require(transport.recordedRequestBodies.first ?? nil)
        let rpcRequest = try JSONDecoder().decode(RecordedRPCRequest.self, from: body)

        #expect(rpcRequest.method == "session-set")
        #expect(rpcRequest.arguments == [
            "download-dir": .string("/new"),
            "speed-limit-down-enabled": .bool(false),
            "seedRatioLimit": .number(2.25),
            "pex-enabled": .bool(true)
        ])
    }

    @Test("reuses session token across sequential calls")
    func reusesSessionTokenAcrossSequentialCalls() async throws {
        let transport = URLProtocolStubTransport(responses: [
            .http(
                status: 409,
                headers: ["X-Transmission-Session-Id": "token-1"],
                body: #"{"result":"success","arguments":{}}"#
            ),
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"downloadSpeed":1,"uploadSpeed":2}}"#
            ),
            .http(
                status: 200,
                headers: [:],
                body: #"{"result":"success","arguments":{"downloadSpeed":3,"uploadSpeed":4}}"#
            )
        ])

        let client = TransmissionRPCClient(config: makeConfig(), session: transport.session)
        let first = try await client.fetchSessionStats()
        let second = try await client.fetchSessionStats()

        #expect(first.downloadSpeed == 1)
        #expect(second.downloadSpeed == 3)
        #expect(transport.recordedRequests.count == 3)
        #expect(transport.recordedRequests[0].value(forHTTPHeaderField: "X-Transmission-Session-Id") == nil)
        #expect(transport.recordedRequests[1].value(forHTTPHeaderField: "X-Transmission-Session-Id") == "token-1")
        #expect(transport.recordedRequests[2].value(forHTTPHeaderField: "X-Transmission-Session-Id") == "token-1")
    }
}

private func makeConfig() -> TransmissionRPCConfig {
    TransmissionRPCConfig(
        profile: RemoteProfile(
            name: "Local",
            rpcURL: URL(string: "http://localhost:9091/transmission/rpc")!,
            username: "test"
        ),
        password: "secret"
    )
}

private struct RecordedRPCRequest: Decodable {
    let method: String
    let arguments: [String: JSONValue]
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class URLProtocolStubTransport: @unchecked Sendable {
    enum StubResponse: Sendable {
        case http(status: Int, headers: [String: String], body: String)
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var queue: [StubResponse]
    private(set) var recordedRequests: [URLRequest] = []
    private(set) var recordedRequestBodies: [Data?] = []
    let session: URLSession

    init(responses: [StubResponse]) {
        self.queue = responses

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        self.session = URLSession(configuration: config)

        URLProtocolStub.handler = { [weak self] request in
            guard let self else { throw URLError(.badServerResponse) }
            return try self.respond(request: request)
        }
    }

    private func respond(request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        recordedRequestBodies.append(request.httpBody ?? Self.bodyData(from: request.httpBodyStream))

        guard !queue.isEmpty else {
            throw URLError(.badServerResponse)
        }

        let next = queue.removeFirst()
        switch next {
        case let .http(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, body.data(using: .utf8)!)
        case let .failure(code):
            throw URLError(code)
        }
    }

    private static func bodyData(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0 {
                return nil
            } else {
                break
            }
        }
        return data
    }
}
