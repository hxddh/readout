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

    /// Pushes the body in paced chunks (64 KB per 2 ms, after a short header-to-body
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
                usleep(2000)
            }
            if !self.isStopped { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
}

/// Test DNS: *.test names are public unless listed here.
let stubDNS: RemoteFetcher.Resolver = { host in
    switch host {
    case "intranet.test": return ["10.0.0.5"]
    case "rebind.test": return ["93.184.216.34", "127.0.0.1"]
    case "v6local.test": return ["fe80::1%en0"]
    case "nxdomain.test": return []
    default: return ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]
    }
}

@Suite(.serialized) struct RemoteFetcherTests {
    func fetch(_ url: String) async -> Result<RemoteFetcher.Image, RemoteFetcher.Failure> {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let fetcher = RemoteFetcher(configuration: config, resolve: stubDNS)
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
        // The transfer is cancelled once the cap is crossed, not run on to
        // 200 MB. The stub pushes data without waiting for the reader, so on a
        // busy machine it runs ahead of the cancel by tens of megabytes (27 and
        // 57 MB observed with a 4 MB bound): the bound here is what separates
        // "cancelled" from "downloaded it all", not a scheduling race.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let sent = StubProtocol.bytesSent("big.test")
        #expect(sent > RemoteLoad.maxBytes)
        #expect(sent < 100 * 1024 * 1024, "sent \(sent) bytes")
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
        let fetcher = RemoteFetcher(resolve: stubDNS)
        defer { fetcher.invalidate() }
        let task = fetcher.session.dataTask(with: URL(string: "https://example.com/a.png")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        func follow(_ target: String) -> URLRequest? {
            nonisolated(unsafe) var out: URLRequest?
            let done = DispatchSemaphore(value: 0)
            fetcher.urlSession(fetcher.session, task: task, willPerformHTTPRedirection: response,
                               newRequest: URLRequest(url: URL(string: target)!)) { out = $0; done.signal() }
            done.wait()
            return out
        }
        #expect(follow("https://cdn.example.com/a.png")?.url?.host == "cdn.example.com")
        #expect(follow("http://127.0.0.1/secret.png") == nil)
        #expect(follow("http://169.254.169.254/latest") == nil)
        #expect(follow("file:///etc/passwd") == nil)
        #expect(follow("https://intranet.test/a.png") == nil)
    }

    /// The redirect check resolves the new host off the session's delegate
    /// queue (serial: a slow name held up every other download's callbacks).
    @Test func redirectCheckDoesNotBlockTheDelegateQueue() {
        let fetcher = RemoteFetcher(resolve: { _ in Thread.sleep(forTimeInterval: 1); return ["93.184.216.34"] })
        defer { fetcher.invalidate() }
        let task = fetcher.session.dataTask(with: URL(string: "https://example.com/a.png")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        nonisolated(unsafe) var out: URLRequest?
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        fetcher.urlSession(fetcher.session, task: task, willPerformHTTPRedirection: response,
                           newRequest: URLRequest(url: URL(string: "https://slow.test/a.png")!)) { out = $0; done.signal() }
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(out?.url?.host == "slow.test")
    }

    @Test func refusesNamesThatResolvePrivately() async {
        for host in ["intranet.test", "rebind.test", "v6local.test"] {
            let result = await fetch("https://\(host)/a.png")
            #expect(result == .failure(.rejected(.privateAddress)), "\(host)")
            #expect(!StubProtocol.didStart(host), "\(host)")
        }
    }

    @Test func boundsASlowResolver() async {
        let fetcher = RemoteFetcher(resolve: { _ in Thread.sleep(forTimeInterval: 3); return ["93.184.216.34"] },
                                    resolveTimeout: 0.2)
        defer { fetcher.invalidate() }
        let start = Date()
        let result = await withCheckedContinuation { cont in
            fetcher.fetch("https://slow.test/a.png") { cont.resume(returning: $0) }
        }
        #expect(result == .failure(.rejected(.unresolved)))
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func refusesNamesThatDoNotResolve() async {
        let result = await fetch("https://nxdomain.test/a.png")
        #expect(result == .failure(.rejected(.unresolved)))
        #expect(!StubProtocol.didStart("nxdomain.test"))
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

    /// An address loaded again replaces its image: the old bytes go, and
    /// they no longer count against the capacity.
    @Test func reloadingAnAddressReplacesItsBytes() {
        var cache = RemoteImageCache(capacity: 100)
        let first = cache.insert(image(40), url: "https://e.com/a.png")!
        let other = cache.insert(image(30), url: "https://e.com/b.png")!
        let second = cache.insert(image(50), url: "https://e.com/a.png")!
        #expect(cache.totalBytes == 80)
        #expect(cache.count == 2)
        #expect(cache.image(for: first) == nil)
        #expect(cache.image(for: other) != nil)   // not evicted for the stale copy
        #expect(cache.token(forURL: "https://e.com/a.png") == second)
        #expect(cache.known.count == 2)
        // Filling up later evicts by what is really kept.
        _ = cache.insert(image(20), url: "https://e.com/c.png")
        #expect(cache.totalBytes == 100 && cache.count == 3)
    }

    @Test func defaultCapacityHoldsSeveralMaxSizeImages() {
        #expect(RemoteImageCache.defaultCapacity >= 5 * RemoteLoad.maxBytes)
    }

    @Test func theCacheRemembersWhichAddressEachImageCameFrom() {
        func image(_ bytes: Int) -> RemoteFetcher.Image { .init(data: Data(count: bytes), contentType: "image/png") }
        var cache = RemoteImageCache(capacity: 100)
        let a = cache.insert(image(40), url: "https://img.example/a.png")!
        #expect(cache.token(forURL: "https://img.example/a.png") == a)
        #expect(cache.token(forURL: "https://img.example/b.png") == nil)
        // Loaded again: the new bytes.
        let a2 = cache.insert(image(40), url: "https://img.example/a.png")!
        #expect(cache.token(forURL: "https://img.example/a.png") == a2)
        #expect(cache.known == ["https://img.example/a.png": a2])
        // Evicted: forgotten, so the reader is asked again.
        _ = cache.insert(image(40), url: "https://img.example/b.png")
        _ = cache.insert(image(40), url: "https://img.example/c.png")
        #expect(cache.token(forURL: "https://img.example/a.png") == nil)
        #expect(Set(cache.known.keys) == ["https://img.example/b.png", "https://img.example/c.png"])
    }
}
