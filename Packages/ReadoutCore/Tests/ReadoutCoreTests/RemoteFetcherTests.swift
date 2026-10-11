import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ReadoutCore

/// In-process HTTP stand-in, routed by host. Records how many body bytes it
/// pushed so tests can prove the fetcher stopped the transfer early.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var sent: [String: Int] = [:]
    nonisolated(unsafe) static var started: Set<String> = []

    static func bytesSent(_ host: String) -> Int { lock.withLock { sent[host] ?? 0 } }
    static func didStart(_ host: String) -> Bool { lock.withLock { started.contains(host) } }

    private let stopLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stopLock.withLock { stopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        Self.lock.withLock { _ = Self.started.insert(host) }
        switch host {
        case "big.test":
            respond(200, ["Content-Type": "image/png"])
            stream(host: host, chunk: 64 * 1024, total: 200 * 1024 * 1024)
        case "declared.test":
            respond(200, ["Content-Type": "image/png", "Content-Length": String(50 * 1024 * 1024)])
            stream(host: host, chunk: 64 * 1024, total: 50 * 1024 * 1024)
        case "html.test":
            respond(200, ["Content-Type": "text/html"])
            stream(host: host, chunk: 1024, total: 64 * 1024)
        case "missing.test":
            respond(404, ["Content-Type": "image/png"])
            client?.urlProtocolDidFinishLoading(self)
        default: // ok.test
            respond(200, ["Content-Type": "image/png"])
            client?.urlProtocol(self, didLoad: Data([0x89, 0x50, 0x4e, 0x47]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { stopLock.withLock { stopped = true } }

    private func respond(_ status: Int, _ headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    /// Pushes the body in paced chunks (64 KB/ms, after a short header-to-body
    /// gap) from a background queue so a cancel can land between chunks, as it
    /// would on a real socket.
    private func stream(host: String, chunk: Int, total: Int) {
        let piece = Data(count: chunk)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
            var sent = 0
            while sent < total, !self.isStopped {
                self.client?.urlProtocol(self, didLoad: piece)
                sent += chunk
                Self.lock.withLock { Self.sent[host] = sent }
                usleep(1000)
            }
            if !self.isStopped { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
}

@Suite(.serialized) struct RemoteFetcherTests {
    func fetch(_ url: String) async -> Result<RemoteFetcher.Image, RemoteFetcher.Failure> {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let fetcher = RemoteFetcher(configuration: config)
        defer { fetcher.invalidate() }
        return await withCheckedContinuation { cont in
            fetcher.fetch(url) { cont.resume(returning: $0) }
        }
    }

    @Test func downloadsAnImage() async {
        let result = await fetch("https://ok.test/a.png")
        #expect(result == .success(.init(data: Data([0x89, 0x50, 0x4e, 0x47]), contentType: "image/png")))
    }

    @Test func protocolRelativeURLsUseHTTPS() async {
        let result = await fetch("//ok.test/a.png")
        #expect((try? result.get())?.contentType == "image/png")
    }

    @Test func cancelsAnEndlessBodyRightAfterTheCap() async {
        let result = await fetch("https://big.test/a.png")
        #expect(result == .failure(.rejected(.tooLarge)))
        // Allow for chunks already in flight when the cancel landed, but the
        // transfer must stop near 20 MB, not run on to 200 MB.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let sent = StubProtocol.bytesSent("big.test")
        #expect(sent > RemoteLoad.maxBytes)
        #expect(sent < RemoteLoad.maxBytes + 2 * 1024 * 1024, "sent \(sent) bytes")
    }

    @Test func rejectsADeclaredOversizeBodyFromTheHeaders() async {
        let result = await fetch("https://declared.test/a.png")
        #expect(result == .failure(.rejected(.tooLarge)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(StubProtocol.bytesSent("declared.test") < 1024 * 1024)
    }

    @Test func rejectsNonImagesFromTheHeaders() async {
        let result = await fetch("https://html.test/page")
        #expect(result == .failure(.rejected(.contentType)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(StubProtocol.bytesSent("html.test") < 64 * 1024)
    }

    @Test func reportsHTTPErrors() async {
        let result = await fetch("https://missing.test/a.png")
        #expect(result == .failure(.httpStatus(404)))
    }

    @Test func refusesPrivateHostsWithoutARequest() async {
        let result = await fetch("http://127.0.0.1/a.png")
        #expect(result == .failure(.rejected(.privateAddress)))
        #expect(!StubProtocol.didStart("127.0.0.1"))
    }

    /// swift-corelibs-foundation cannot deliver URLProtocol redirects, so the
    /// redirect decision is exercised through the delegate method directly.
    @Test func refusesRedirectsToPrivateHosts() {
        let fetcher = RemoteFetcher()
        defer { fetcher.invalidate() }
        let task = fetcher.session.dataTask(with: URL(string: "https://example.com/a.png")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        func follow(_ target: String) -> URLRequest? {
            nonisolated(unsafe) var out: URLRequest?
            fetcher.urlSession(fetcher.session, task: task, willPerformHTTPRedirection: response,
                               newRequest: URLRequest(url: URL(string: target)!)) { out = $0 }
            return out
        }
        #expect(follow("https://cdn.example.com/a.png")?.url?.host == "cdn.example.com")
        #expect(follow("http://127.0.0.1/secret.png") == nil)
        #expect(follow("http://169.254.169.254/latest") == nil)
        #expect(follow("file:///etc/passwd") == nil)
    }
}

@Suite struct RemoteImageCacheTests {
    func image(_ bytes: Int) -> RemoteFetcher.Image { .init(data: Data(count: bytes), contentType: "image/png") }

    @Test func evictsLeastRecentlyUsedPastCapacity() {
        var cache = RemoteImageCache(capacity: 100)
        let a = cache.insert(image(40))!
        let b = cache.insert(image(40))!
        _ = cache.image(for: a)                       // a is now most recent
        let c = cache.insert(image(40))!              // evicts b
        let hits = [a, b, c].map { cache.image(for: $0) != nil }
        #expect(hits == [true, false, true])
        #expect(cache.totalBytes == 80)
        #expect(cache.count == 2)
    }

    @Test func neverExceedsCapacity() {
        var cache = RemoteImageCache(capacity: 1000)
        for i in 0..<200 { _ = cache.insert(image(37 + i % 50)) }
        #expect(cache.totalBytes <= 1000)
    }

    @Test func refusesAnImageLargerThanTheCache() {
        var cache = RemoteImageCache(capacity: 10)
        let token = cache.insert(image(11))
        #expect(token == nil)
        #expect(cache.count == 0)
    }

    @Test func defaultCapacityHoldsSeveralMaxSizeImages() {
        #expect(RemoteImageCache.defaultCapacity >= 5 * RemoteLoad.maxBytes)
    }
}
