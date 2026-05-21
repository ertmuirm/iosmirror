import Foundation
import Darwin

// Thin helper used by MirrorBridge and DLNADiscovery to compute the URL
// the BroadcastExtension serves on port 8080.
// The actual HLS encoding and HTTP server live entirely in the extension process.
final class HLSStreamServer {

    static let shared = HLSStreamServer()
    private init() {}

    /// URL of the live HLS stream the extension serves.
    var streamURL: URL? {
        guard let ip = detectLocalIP() else { return nil }
        return URL(string: "http://\(ip):8080/stream/index.m3u8")
    }

    /// Returns the device's current en0 (WiFi) IPv4 address, or nil if not on WiFi.
    func detectLocalIP() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0 else { return nil }
        defer { freeifaddrs(addr) }
        var ptr = addr
        while let p = ptr {
            let sa = p.pointee.ifa_addr!
            if sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: p.pointee.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    return String(cString: host)
                }
            }
            ptr = p.pointee.ifa_next
        }
        return nil
    }
}
