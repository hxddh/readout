import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads one remote image under `RemoteLoad` policy, streaming:
/// the URL (and every redirect target) is checked before a request goes out,
/// including every address its host name resolves to,
/// status, `Content-Type` and `Content-Length` are checked on the response
/// headers before any body is accepted, and the body is counted as it arrives
/// so an oversized or lying server is cancelled as soon as it passes the cap.
///
/// The session is ephemeral (no cookies, no shared cache). Completion runs on
/// the session's delegate queue; callers hop to their own actor.
public final class RemoteFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public struct Image: Sendable, Equatable {
        public let data: Data
        public let contentType: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case rejected(RemoteLoad.Rejection)
        case httpStatus(Int)
        case network(code: Int)
    }

    public typealias Completion = @Sendable (Result<Image, Failure>) -> Void

    private final class Pending {
        let completion: Completion
        var data = Data()
        var contentType = ""
        var failure: Failure?
        init(_ completion: @escaping Completion) { self.completion = completion }
    }

    public typealias Resolver = @Sendable (String) -> [String]

    private let maxBytes: Int
    private let resolve: Resolver
    private let resolveTimeout: TimeInterval
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private(set) var session: URLSession!

    /// `configuration` is copied; tests pass one with stub `protocolClasses`.
    /// `resolve` maps a host name to numeric addresses (tests inject one).
    public init(configuration: URLSessionConfiguration = .ephemeral, maxBytes: Int = RemoteLoad.maxBytes,
                resolve: @escaping Resolver = RemoteLoad.systemResolve,
                resolveTimeout: TimeInterval = RemoteLoad.timeoutSeconds) {
        self.maxBytes = maxBytes
        self.resolve = resolve
        self.resolveTimeout = resolveTimeout
        super.init()
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = RemoteLoad.timeoutSeconds
        configuration.timeoutIntervalForResource = RemoteLoad.timeoutSeconds
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Stops accepting work and lets in-flight downloads finish (the session
    /// retains its delegate until then).
    public func invalidate() { session.finishTasksAndInvalidate() }

    public func fetch(_ urlString: String, completion: @escaping Completion) {
        // Protocol-relative URLs inherit https.
        let urlString = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        if let r = RemoteLoad.check(urlString) {
            completion(.failure(.rejected(r)))
            return
        }
        let url = URL(string: urlString)!
        // Name resolution blocks: do it off the caller's thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let r = checkResolution(url) {
                completion(.failure(.rejected(r)))
                return
            }
            let task = session.dataTask(with: url)
            lock.withLock { pending[task.taskIdentifier] = Pending(completion) }
            task.resume()
        }
    }

    /// Every address a host name resolves to must be public. Literal
    /// addresses were already checked by `RemoteLoad.check`.
    ///
    /// URLSession resolves again when it connects, so a name that changes its
    /// answer in between (DNS rebinding) is not covered; for a click-to-load
    /// image that narrow window is accepted.
    private func checkResolution(_ url: URL) -> RemoteLoad.Rejection? {
        guard let host = url.host, !RemoteLoad.isAddressLiteral(host) else { return nil }
        guard let addresses = resolveWithDeadline(host) else { return .unresolved }
        return RemoteLoad.checkResolved(addresses)
    }

    /// `getaddrinfo` has no timeout of its own and runs before the
    /// URLSession task (whose timeouts don't cover it), so bound it here.
    /// A late answer is ignored. Nil on timeout.
    private func resolveWithDeadline(_ host: String) -> [String]? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: [String]?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let resolve = self.resolve
        DispatchQueue.global(qos: .userInitiated).async {
            let addresses = resolve(host)
            box.lock.withLock { box.value = addresses }
            done.signal()
        }
        guard done.wait(timeout: .now() + resolveTimeout) == .success else { return nil }
        return box.lock.withLock { box.value }
    }

    private func entry(_ task: URLSessionTask) -> Pending? {
        lock.withLock { pending[task.taskIdentifier] }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let r = RemoteLoad.check(request.url?.absoluteString ?? "") ?? request.url.flatMap(checkResolution) {
            entry(task)?.failure = .rejected(r)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // Missing, or already refused (a rejected redirect still delivers its 3xx):
        // keep the first reason.
        guard let p = entry(dataTask), p.failure == nil else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        if !(200..<300).contains(status) {
            p.failure = .httpStatus(status)
        } else if let r = RemoteLoad.checkContentType(contentType) {
            p.failure = .rejected(r)
        } else if response.expectedContentLength > Int64(maxBytes) {
            p.failure = .rejected(.tooLarge)
        }
        if p.failure != nil {
            completionHandler(.cancel)
            dataTask.cancel()   // explicit: not every Foundation stops the transfer on `.cancel` alone
            return
        }
        p.contentType = contentType ?? "image/png"
        if response.expectedContentLength > 0 { p.data.reserveCapacity(Int(response.expectedContentLength)) }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let p = entry(dataTask), p.failure == nil else { return }
        if p.data.count + data.count > maxBytes {
            p.failure = .rejected(.tooLarge)
            p.data = Data()
            dataTask.cancel()
            return
        }
        p.data.append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = p.failure {
            p.completion(.failure(failure))
        } else if let error {
            p.completion(.failure(.network(code: (error as NSError).code)))
        } else {
            p.completion(.success(Image(data: p.data, contentType: p.contentType)))
        }
    }
}

/// Proxied images keyed by unguessable token, bounded by total bytes and
/// evicting the least recently used entry first.
public struct RemoteImageCache {
    public static let defaultCapacity = 100 * 1024 * 1024

    public let capacity: Int
    public private(set) var totalBytes = 0
    private var entries: [String: RemoteFetcher.Image] = [:]
    private var order: [String] = []   // least recent first
    /// The image each address was loaded as, while its bytes are kept: the
    /// reader agreed to load that address, so a block drawn again (an edit,
    /// a reopened window) shows it without asking again.
    private var tokenForURL: [String: String] = [:]
    private var urlForToken: [String: String] = [:]

    public init(capacity: Int = RemoteImageCache.defaultCapacity) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    /// Stores `image` and returns its new token. An image larger than the
    /// whole cache is not kept (returns nil).
    public mutating func insert(_ image: RemoteFetcher.Image) -> String? {
        let size = image.data.count
        guard size <= capacity else { return nil }
        while totalBytes + size > capacity, let oldest = order.first {
            order.removeFirst()
            totalBytes -= entries.removeValue(forKey: oldest)?.data.count ?? 0
            if let url = urlForToken.removeValue(forKey: oldest), tokenForURL[url] == oldest { tokenForURL[url] = nil }
        }
        let token = UUID().uuidString
        entries[token] = image
        order.append(token)
        totalBytes += size
        return token
    }

    /// Stores `image`, loaded from `url`, and returns its new token.
    public mutating func insert(_ image: RemoteFetcher.Image, url: String) -> String? {
        guard let token = insert(image) else { return nil }
        if let old = tokenForURL[url] { urlForToken[old] = nil }
        tokenForURL[url] = token
        urlForToken[token] = url
        return token
    }

    /// The token of the image loaded from `url`, while its bytes are kept.
    public func token(forURL url: String) -> String? {
        guard let token = tokenForURL[url], entries[token] != nil else { return nil }
        return token
    }

    /// Every address loaded whose bytes are kept, with its token.
    public var known: [String: String] { tokenForURL }

    /// Looks up a token and marks it most recently used.
    public mutating func image(for token: String) -> RemoteFetcher.Image? {
        guard let image = entries[token] else { return nil }
        if let i = order.firstIndex(of: token) {
            order.remove(at: i)
            order.append(token)
        }
        return image
    }
}
