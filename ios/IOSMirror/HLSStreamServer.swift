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
        return en0Info()?.ip
    }

    /// Returns the WiFi broadcast address (e.g. "192.168.1.255"), or nil.
    func detectBroadcastAddress() -> String? {
        return en0Info()?.broadcast
    }

    private func en0Info() -> (ip: String, broadcast: String)? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0 else { return nil }
        defer { freeifaddrs(addr) }
        var ptr = addr
        while let p = ptr {
            guard let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: p.pointee.ifa_name) == "en0"
            else { ptr = p.pointee.ifa_next; continue }

            var ipBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                        &ipBuf, socklen_t(ipBuf.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: ipBuf)

            var bcast = "255.255.255.255"
            if let dstSA = p.pointee.ifa_dstaddr, dstSA.pointee.sa_family == UInt8(AF_INET) {
                var bBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(dstSA, socklen_t(dstSA.pointee.sa_len),
                            &bBuf, socklen_t(bBuf.count), nil, 0, NI_NUMERICHOST)
                bcast = String(cString: bBuf)
            }
            return (ip, bcast)
        }
        return nil
    }
}
