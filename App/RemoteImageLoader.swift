import Foundation
import ReadoutCore

/// Downloads a remote image on the reader's behalf. The page itself can never
/// fetch (its CSP allows no http:/https: sources), so placeholder clicks come
/// in as `loadRemote` messages and the bytes are served back to the page over
/// `readout://remote/<token>`.
///
/// Privacy properties: ephemeral URLSession (no cookies, no shared cache),
/// 15 s timeout, 20 MB cap, `image/*` responses only. Redirect targets are
/// re-validated through the same scheme/content-type checks.
@MainActor
final class RemoteImageLoader: NSObject, URLSessionTaskDelegate {
    struct Entry {
        let data: Data
        let contentType: String
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = RemoteLoad.timeoutSeconds
        config.timeoutIntervalForResource = RemoteLoad.timeoutSeconds
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// token -> cached bytes. Tokens are random UUIDs, unguessable across documents.
    private var cache: [String: Entry] = [:]

    static let shared = RemoteImageLoader()

    /// Validates `urlString`, downloads, caches, and completes with the
    /// `readout://remote/<token>` URL string (or an Error with a readable message).
    func load(_ urlString: String, completion: @escaping (Result<String, Error>) -> Void) {
        // Protocol-relative URLs inherit https.
        let urlString = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        if RemoteLoad.checkScheme(urlString) != nil {
            completion(.failure(LoadError.rejected("unsupported address")))
            return
        }
        let task = session.dataTask(with: URL(string: urlString)!) { [weak self] data, response, error in
            Task { @MainActor in self?.finish(urlString: urlString, data: data, response: response, error: error, completion: completion) }
        }
        task.resume()
    }

    private func finish(urlString: String, data: Data?, response: URLResponse?, error: Error?,
                        completion: (Result<String, Error>) -> Void) {
        if let error {
            completion(.failure(LoadError.rejected(shortError(error))))
            return
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completion(.failure(LoadError.rejected("the server answered with an error")))
            return
        }
        if RemoteLoad.checkContentType(http.value(forHTTPHeaderField: "Content-Type")) != nil {
            completion(.failure(LoadError.rejected("not an image")))
            return
        }
        guard let data, RemoteLoad.checkLength(data.count) == nil else {
            completion(.failure(LoadError.rejected("image is too large")))
            return
        }
        let token = UUID().uuidString
        let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
        cache[token] = Entry(data: data, contentType: ct)
        completion(.success("readout://remote/\(token)"))
    }

    private func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "timed out"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return "could not be reached"
            case NSURLErrorUserCancelledAuthentication, NSURLErrorSecureConnectionFailed:
                return "the secure connection failed"
            default: break
            }
        }
        return "could not be loaded"
    }

    enum LoadError: Error {
        case rejected(String)
    }

    /// Looks up cached bytes for a `readout://remote/<token>` path.
    func entry(for token: String) -> Entry? { cache[token] }

    /// Redirects re-enter validation: only http/https targets are followed.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        let target = request.url?.absoluteString ?? ""
        completionHandler(RemoteLoad.checkScheme(target) == nil ? request : nil)
    }
}
