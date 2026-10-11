import Foundation
import Testing
@testable import ReadoutCore

@Suite struct RemoteLoadTests {
    @Test func rejectsNonHTTPSchemes() {
        #expect(RemoteLoad.checkScheme("file:///etc/passwd") == .scheme)
        #expect(RemoteLoad.checkScheme("ftp://example.com/a.png") == .scheme)
        #expect(RemoteLoad.checkScheme("javascript:alert(1)") == .scheme)
        #expect(RemoteLoad.checkScheme("data:image/png;base64,AAA") == .scheme)
        #expect(RemoteLoad.checkScheme("not a url") == .scheme)
    }

    @Test func acceptsHTTPAndHTTPS() {
        #expect(RemoteLoad.checkScheme("https://example.com/a.png") == nil)
        #expect(RemoteLoad.checkScheme("http://example.com/a.png") == nil)
        #expect(RemoteLoad.checkScheme("HTTPS://EXAMPLE.COM/A.PNG") == nil)
    }

    @Test func rejectsNonImageContentTypes() {
        #expect(RemoteLoad.checkContentType("text/html") == .contentType)
        #expect(RemoteLoad.checkContentType("text/html; charset=utf-8") == .contentType)
        #expect(RemoteLoad.checkContentType(nil) == .contentType)
        #expect(RemoteLoad.checkContentType("") == .contentType)
        #expect(RemoteLoad.checkContentType("application/octet-stream") == .contentType)
    }

    @Test func acceptsImageContentTypes() {
        #expect(RemoteLoad.checkContentType("image/png") == nil)
        #expect(RemoteLoad.checkContentType("Image/JPEG; charset=binary") == nil)
        #expect(RemoteLoad.checkContentType("image/svg+xml") == nil)
    }

    @Test func enforcesSizeLimit() {
        #expect(RemoteLoad.checkLength(0) == nil)
        #expect(RemoteLoad.checkLength(RemoteLoad.maxBytes) == nil)
        #expect(RemoteLoad.checkLength(RemoteLoad.maxBytes + 1) == .tooLarge)
    }
}
