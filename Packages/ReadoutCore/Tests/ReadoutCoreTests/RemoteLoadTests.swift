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

    @Test func rejectsLocalAndPrivateHosts() {
        let blocked = [
            "http://localhost/a.png", "http://LOCALHOST./a.png", "http://dev.localhost/a.png",
            "http://printer.local/a.png", "http://metadata.google.internal/a.png", "http://nas.home.arpa/a.png",
            "http://127.0.0.1/a.png", "http://127.1.2.3:8080/a.png", "http://0.0.0.0/a.png",
            "http://10.0.0.1/a.png", "http://172.16.0.1/a.png", "http://172.31.255.255/a.png",
            "http://192.168.1.1/a.png", "http://169.254.169.254/latest/meta-data", "http://100.64.0.1/a.png",
            "http://224.0.0.1/a.png", "http://255.255.255.255/a.png",
            // Numeric spellings resolvers read as 127.0.0.1.
            "http://2130706433/a.png", "http://0x7f000001/a.png", "http://0x7f.1/a.png",
            "http://0177.0.0.1/a.png", "http://127.1/a.png", "http://127.0.0.01/a.png",
            // IPv6 literals.
            "http://[::1]/a.png", "http://[::]/a.png", "http://[0:0:0:0:0:0:0:1]/a.png",
            "http://[fe80::1]/a.png", "http://[fd00::1]/a.png", "http://[fc12:3456::1]/a.png",
            "http://[ff02::1]/a.png", "http://[::ffff:127.0.0.1]/a.png", "http://[::ffff:7f00:1]/a.png",
            "http://[::ffff:10.1.2.3]/a.png", "http://[64:ff9b::192.168.0.1]/a.png", "http://[::127.0.0.1]/a.png",
            "http://[not:an:address]/a.png",
        ]
        for url in blocked {
            #expect(RemoteLoad.check(url) == .privateAddress, "\(url)")
        }
    }

    @Test func allowsPublicHosts() {
        let allowed = [
            "https://example.com/a.png", "https://raw.githubusercontent.com/o/r/main/a.png",
            "https://1e100.net/a.png", "https://123.example/a.png", "https://cafe.de/a.png",
            "http://8.8.8.8/a.png", "http://172.32.0.1/a.png", "http://192.169.0.1/a.png",
            "http://[2606:4700:4700::1111]/a.png", "http://[::ffff:8.8.8.8]/a.png",
            "http://[64:ff9b::8.8.8.8]/a.png",
        ]
        for url in allowed {
            #expect(RemoteLoad.check(url) == nil, "\(url)")
        }
    }

    @Test func checkRejectsSchemeFirst() {
        #expect(RemoteLoad.check("file:///etc/passwd") == .scheme)
        #expect(RemoteLoad.check("ftp://127.0.0.1/a.png") == .scheme)
    }

    @Test func parsesIPv6Forms() {
        #expect(RemoteLoad.parseIPv6("::1") == Array(repeating: 0, count: 15) + [1])
        #expect(RemoteLoad.parseIPv6("1:2:3:4:5:6:7:8")?.count == 16)
        #expect(RemoteLoad.parseIPv6("::ffff:1.2.3.4")?.suffix(4) == [1, 2, 3, 4])
        #expect(RemoteLoad.parseIPv6("1:2:3:4:5:6:7:8:9") == nil)
        #expect(RemoteLoad.parseIPv6("1::2::3") == nil)
        #expect(RemoteLoad.parseIPv6("12345::") == nil)
        #expect(RemoteLoad.parseIPv6("::ffff:1.2.3") == nil)
    }
}
