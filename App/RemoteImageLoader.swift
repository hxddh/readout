import Foundation
import ReadoutCore

/// Downloads a remote image on the reader's behalf. The page itself can never
/// fetch (its CSP allows no http:/https: sources), so placeholder clicks come
/// in as `loadRemote` messages and the bytes are served back to the page over
/// `readout://remote/<token>`.
///
/// Policy lives in ReadoutCore (`RemoteLoad`, `RemoteFetcher`): public hosts
/// only, ephemeral session, 15 s timeout, `image/*` only, 20 MB cap enforced
/// while streaming. Downloads are kept in a 100 MB least-recently-used cache.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let fetcher = RemoteFetcher()
    private var cache = RemoteImageCache()

    enum LoadError: Error {
        case rejected(String)
    }

    /// Downloads `urlString` and completes on the main actor with the
    /// `readout://remote/<token>` URL string, or a `LoadError` whose message
    /// is shown in the placeholder.
    func load(_ urlString: String, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        fetcher.fetch(urlString) { [self] result in
            Task { @MainActor in
                switch result {
                case .success(let image):
                    if let token = cache.insert(image) {
                        completion(.success("readout://remote/\(token)"))
                    } else {
                        completion(.failure(LoadError.rejected(Self.reason(.rejected(.tooLarge)))))
                    }
                case .failure(let failure):
                    completion(.failure(LoadError.rejected(Self.reason(failure))))
                }
            }
        }
    }

    /// Cached bytes for a `readout://remote/<token>` path.
    func entry(for token: String) -> RemoteFetcher.Image? { cache.image(for: token) }

    private static func reason(_ failure: RemoteFetcher.Failure) -> String {
        switch failure {
        case .rejected(.scheme):
            return NSLocalizedString("unsupported address", comment: "Remote image failure reason")
        case .rejected(.privateAddress):
            return NSLocalizedString("local and private network addresses are not loaded", comment: "Remote image failure reason")
        case .rejected(.contentType):
            return NSLocalizedString("not an image", comment: "Remote image failure reason")
        case .rejected(.tooLarge):
            return NSLocalizedString("image is larger than 20 MB", comment: "Remote image failure reason")
        case .httpStatus:
            return NSLocalizedString("the server answered with an error", comment: "Remote image failure reason")
        case .network(let code):
            switch code {
            case NSURLErrorTimedOut:
                return NSLocalizedString("timed out", comment: "Remote image failure reason")
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed:
                return NSLocalizedString("could not be reached", comment: "Remote image failure reason")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot:
                return NSLocalizedString("the secure connection failed", comment: "Remote image failure reason")
            default:
                return NSLocalizedString("could not be loaded", comment: "Remote image failure reason")
            }
        }
    }
}
