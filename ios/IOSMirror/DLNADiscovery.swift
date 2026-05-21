import Foundation
import Darwin

struct DLNADevice {
    let id: String
    let name: String
    let manufacturer: String
    let controlURL: URL
}

/// Discovers DLNA MediaRenderer devices via SSDP and Samsung TVs via mDNS.
///
/// Three-pronged discovery:
///   1. Active M-SEARCH on the WiFi interface with five ST values.
///   2. Passive NOTIFY listener on port 1900 (multicast group membership).
///   3. NetServiceBrowser for _samsungtvpresence._tcp.
///
/// For every SSDP hit the device's friendly name is logged (even when the
/// description has no AVTransport) so you can see in the debug panel exactly
/// which device is being found and why it's accepted or rejected.
/// When a Samsung-branded device is found without AVTransport in its root
/// description, we probe Samsung-specific MediaRenderer description paths
/// on the same host before giving up.
final class DLNADiscovery {

    var onUpdate: (([DLNADevice]) -> Void)?
    var onDebug:  ((String) -> Void)?

    private var running = false
    private var knownUUIDs:   Set<String>          = []
    private var knownDevices: [String: DLNADevice] = [:]

    private let searchQueue   = DispatchQueue(label: "com.iosmirror.dlna.search",   qos: .utility)
    private let listenerQueue = DispatchQueue(label: "com.iosmirror.dlna.listener", qos: .utility)

    private var mdnsBrowser: SamsungMDNSBrowser?

    private let searchTargets: [String] = [
        "upnp:rootdevice",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:dial-multiscreen-org:service:dial:1",
        "urn:samsung.com:device:RemoteControlReceiver:1",
        "ssdp:all",
    ]

    // Probed when Samsung device found via SSDP root-desc without AVTransport,
    // or via mDNS.  Port 7676 is Samsung's primary DLNA port.
    private let samsungDMRProbes: [(port: Int, path: String)] = [
        (7676,  "/dmr/SamsungMRDesc.xml"),
        (7676,  "/MediaRenderer.xml"),
        (52235, "/dmr/SamsungMRDesc.xml"),
        (52235, "/MediaRenderer.xml"),
        (55001, "/MainTVServer2desc.xml"),
        (7676,  "/"),
    ]

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        scheduleMSearchCycle()
        listenerQueue.async { [weak self] in self?.runNotifyListener() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let b = SamsungMDNSBrowser()
            b.onDeviceFound = { [weak self] host in
                self?.onDebug?("dlna_mdns_found:\(host)")
                self?.searchQueue.async { self?.probeSamsungDMR(host: host, port: 7676, id: "samsung-\(host)", name: nil, mfr: nil) }
            }
            b.start()
            self.mdnsBrowser = b
        }
    }

    func stop() {
        running = false
        DispatchQueue.main.async { [weak self] in
            self?.mdnsBrowser?.stop()
            self?.mdnsBrowser = nil
        }
    }

    // MARK: - Active M-SEARCH

    private func scheduleMSearchCycle() {
        guard running else { return }
        searchQueue.async { [weak self] in
            self?.performMSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.scheduleMSearchCycle()
            }
        }
    }

    private func performMSearch() {
        guard let localIPStr = HLSStreamServer.shared.detectLocalIP() else {
            onDebug?("dlna_no_wifi_ip"); return
        }
        onDebug?("dlna_search_start:\(localIPStr)")

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { onDebug?("dlna_socket_failed"); return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Use an ephemeral source port — binding to 1900 causes sendto() to fail
        // on iOS (EACCES) when the NOTIFY listener already holds 0.0.0.0:1900.
        // The NOTIFY listener on port 1900 will catch any unicast 200 OK replies
        // that the TV sends back to port 1900.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = 0
        local.sin_addr   = in_addr(s_addr: inet_addr(localIPStr))
        guard withUnsafePointer(to: &local, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }) else { onDebug?("dlna_bind_failed:\(errno)"); return }

        var mcastIf = in_addr(s_addr: inet_addr(localIPStr))
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF, &mcastIf, socklen_t(MemoryLayout<in_addr>.size))
        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var sentCount = 0
        for st in searchTargets {
            if sendMSearch(sock: sock, st: st) { sentCount += 1 }
            Thread.sleep(forTimeInterval: 0.25)
        }
        onDebug?("dlna_search_sent:\(sentCount)")

        var seen = Set<String>()
        var buf  = [UInt8](repeating: 0, count: 8192)
        var responseCount = 0
        while running {
            let n = recv(sock, &buf, buf.count - 1, 0)
            if n <= 0 { break }
            buf[Int(n)] = 0
            let msg = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            responseCount += 1
            handleSSDPMessage(msg, localSeen: &seen, source: "msearch")
        }
        onDebug?("dlna_search_responses:\(responseCount)")
    }

    @discardableResult
    private func sendMSearch(sock: Int32, st: String) -> Bool {
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 5\r\nST: \(st)\r\n\r\n"
        guard let data = msg.data(using: .utf8) else { return false }
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port   = UInt16(1900).bigEndian
        dest.sin_addr   = in_addr(s_addr: inet_addr("239.255.255.250"))
        let n = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, bytes.baseAddress, bytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n == data.count
    }

    // MARK: - Passive NOTIFY listener

    private func runNotifyListener() {
        guard let localIPStr = HLSStreamServer.shared.detectLocalIP() else { return }
        onDebug?("dlna_notify_listener_starting")

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = UInt16(1900).bigEndian
        local.sin_addr   = in_addr(s_addr: 0)
        guard withUnsafePointer(to: &local, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }) else { onDebug?("dlna_notify_bind_failed:\(errno)"); return }

        var mreq = ip_mreq()
        mreq.imr_multiaddr = in_addr(s_addr: inet_addr("239.255.255.250"))
        mreq.imr_interface = in_addr(s_addr: inet_addr(localIPStr))
        let joined = setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                                &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
        onDebug?("dlna_notify_listener_ready:joined=\(joined)")

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf  = [UInt8](repeating: 0, count: 8192)
        var seen = Set<String>()
        while running {
            let n = recv(sock, &buf, buf.count - 1, 0)
            if n <= 0 { continue }
            buf[Int(n)] = 0
            let msg = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            // Accept NOTIFY announcements AND 200 OK unicast replies — Samsung
            // TVs sometimes unicast M-SEARCH replies back to port 1900 instead
            // of our ephemeral source port.
            let up = msg.uppercased()
            if up.hasPrefix("NOTIFY") || up.hasPrefix("HTTP/1.1 200") || msg.contains("ssdp:alive") {
                handleSSDPMessage(msg, localSeen: &seen, source: "notify")
            }
        }
        setsockopt(sock, IPPROTO_IP, IP_DROP_MEMBERSHIP,
                   &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
    }

    // MARK: - SSDP message handling

    private func handleSSDPMessage(_ msg: String, localSeen: inout Set<String>, source: String) {
        // Samsung TVs sometimes use bare \n instead of \r\n.
        let lines = msg.components(separatedBy: "\r\n").flatMap {
            $0.components(separatedBy: "\n")
        }
        var location: String?
        var usn: String?
        var nt: String?
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("usn:") {
                usn = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("nt:") {
                nt = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Log every distinct packet so we can see the TV is actually responding.
        let firstLine = lines.first ?? ""
        onDebug?("dlna_\(source)_pkt:\(firstLine.prefix(60)):loc=\(location ?? "nil"):usn=\(usn?.prefix(20) ?? "nil")")

        guard let loc = location else { return }
        // USN is optional — fall back to location as the dedup key for unusual devices.
        let rawUSN = usn ?? loc
        let uuid = deviceUUID(from: rawUSN)
        guard !localSeen.contains(loc), !knownUUIDs.contains(uuid) else { return }
        localSeen.insert(loc)
        knownUUIDs.insert(uuid)
        onDebug?("dlna_\(source)_hit:\(uuid.prefix(8)):\(loc)")
        guard let url = URL(string: loc) else {
            onDebug?("dlna_\(source)_bad_url:\(loc)")
            return
        }
        fetchAndRegister(from: url, id: uuid)
    }

    private func deviceUUID(from usn: String) -> String {
        let s = usn.hasPrefix("uuid:") ? String(usn.dropFirst(5)) : usn
        return s.components(separatedBy: "::").first ?? s
    }

    // MARK: - Device description fetch and register

    private func fetchAndRegister(from url: URL, id: String) {
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        URLSession.shared.dataTask(with: url) { d, _, _ in data = d; sem.signal() }.resume()
        sem.wait()
        guard let data, let xml = String(data: data, encoding: .utf8) else {
            onDebug?("dlna_fetch_failed:\(url.host ?? "?")")
            return
        }

        let result = DescriptionParser(xml: xml, baseURL: url, id: id).parseResult()
        let label  = "\(result.friendlyName.isEmpty ? "?" : result.friendlyName) [\(result.shortType)]"

        if let controlURL = result.controlURL {
            onDebug?("dlna_added:\(label)")
            let device = DLNADevice(id: id, name: result.friendlyName,
                                    manufacturer: result.manufacturer,
                                    controlURL: controlURL)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.knownDevices[id] = device
                self.onUpdate?(Array(self.knownDevices.values))
            }
        } else if result.isSamsung, let host = url.host {
            // Samsung root description without AVTransport — the MediaRenderer
            // is served at a separate URL; probe Samsung-specific paths.
            onDebug?("dlna_samsung_no_avt:\(label):probing_dmr")
            probeSamsungDMR(host: host, port: url.port ?? 7676, id: id,
                            name: result.friendlyName, mfr: result.manufacturer)
        } else {
            onDebug?("dlna_rejected:\(label):no_avt")
        }
    }

    // MARK: - Samsung MediaRenderer probe

    /// After finding a Samsung device whose root description lacks AVTransport,
    /// probe well-known Samsung DLNA MediaRenderer description paths on the
    /// same host.  Also called directly from the mDNS path.
    private func probeSamsungDMR(host: String, port: Int, id: String,
                                  name: String?, mfr: String?) {
        guard knownDevices[id] == nil else { return }   // already added

        for (probePort, probePath) in samsungDMRProbes {
            guard let url = URL(string: "http://\(host):\(probePort)\(probePath)") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 3)
            let sem = DispatchSemaphore(value: 0)
            var hit: (Data, URL)?
            URLSession.shared.dataTask(with: req) { d, resp, _ in
                if let d, (resp as? HTTPURLResponse)?.statusCode == 200 { hit = (d, url) }
                sem.signal()
            }.resume()
            sem.wait()

            if let (data, baseURL) = hit, let xml = String(data: data, encoding: .utf8) {
                let result = DescriptionParser(xml: xml, baseURL: baseURL, id: id).parseResult()
                if let controlURL = result.controlURL {
                    let displayName = name ?? result.friendlyName
                    let displayMfr  = mfr  ?? result.manufacturer
                    onDebug?("dlna_samsung_dmr_added:\(displayName):\(host):\(probePort)\(probePath)")
                    let device = DLNADevice(id: id, name: displayName,
                                           manufacturer: displayMfr, controlURL: controlURL)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.knownDevices[id] = device
                        self.onUpdate?(Array(self.knownDevices.values))
                    }
                    return
                } else {
                    onDebug?("dlna_samsung_probe_no_avt:\(host):\(probePort)\(probePath)")
                }
            }
        }
        onDebug?("dlna_samsung_probe_exhausted:\(host)")
    }
}

// MARK: - Samsung SmartHub mDNS browser

private final class SamsungMDNSBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onDeviceFound: ((String) -> Void)?
    private let browser  = NetServiceBrowser()
    private var pending: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_samsungtvpresence._tcp", inDomain: "local.")
    }

    func stop() { browser.stop(); pending.forEach { $0.stop() }; pending = [] }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pending.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let ip = ipv4Address(from: sender) { onDeviceFound?(ip) }
        pending.removeAll { $0 === sender }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {}

    private func ipv4Address(from service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = data.withUnsafeBytes { ptr -> Bool in
                guard let addr = ptr.bindMemory(to: sockaddr.self).baseAddress else { return false }
                guard addr.pointee.sa_family == sa_family_t(AF_INET) else { return false }
                return getnameinfo(addr, socklen_t(data.count), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0
            }
            if ok { return String(cString: host) }
        }
        return nil
    }
}

// MARK: - UPnP device description XML parser

private struct ParseResult {
    let friendlyName: String
    let manufacturer: String
    let deviceType:   String      // first <deviceType> seen
    let controlURL:   URL?        // nil if no AVTransport found anywhere in tree

    /// Short device type token for logging (e.g. "MainTVServer2:1").
    var shortType: String { deviceType.components(separatedBy: ":").last ?? deviceType }

    var isSamsung: Bool {
        manufacturer.lowercased().contains("samsung") ||
        deviceType.lowercased().contains("samsung")
    }
}

/// Walks the entire device / sub-device tree looking for an AVTransport
/// service.  Samsung SmartHub TVs embed it inside a child device under a
/// Samsung-proprietary root device type.  Also captures the root device's
/// friendlyName, manufacturer, and deviceType for logging regardless of
/// whether AVTransport is found.
private final class DescriptionParser: NSObject, XMLParserDelegate {
    private let xml: String
    private let baseURL: URL
    private let id: String

    private var path:          [String] = []
    private var friendlyName   = ""
    private var manufacturer   = ""
    private var deviceType     = ""
    private var avControlURL   = ""
    private var curServiceType = ""
    private var curControlURL  = ""

    init(xml: String, baseURL: URL, id: String) {
        self.xml = xml; self.baseURL = baseURL; self.id = id
    }

    func parseResult() -> ParseResult {
        if let data = xml.data(using: .utf8) {
            let p = XMLParser(data: data)
            p.delegate = self
            p.parse()
        }
        let controlURL: URL? = avControlURL.isEmpty ? nil :
            URL(string: avControlURL, relativeTo: baseURL)?.absoluteURL
        return ParseResult(friendlyName: friendlyName,
                           manufacturer: manufacturer.isEmpty ? "DLNA" : manufacturer,
                           deviceType:   deviceType,
                           controlURL:   controlURL)
    }

    // Kept for callers that still use the old API.
    func parse() -> DLNADevice? {
        let r = parseResult()
        guard let ctrl = r.controlURL, !r.friendlyName.isEmpty else { return nil }
        return DLNADevice(id: id, name: r.friendlyName, manufacturer: r.manufacturer, controlURL: ctrl)
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) { path.append(name) }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let tag = path.last else { return }
        switch tag {
        case "friendlyName": if friendlyName.isEmpty  { friendlyName  += s }
        case "manufacturer": if manufacturer.isEmpty  { manufacturer  += s }
        case "deviceType":   if deviceType.isEmpty    { deviceType    += s }
        case "serviceType":  curServiceType += s
        case "controlURL":   curControlURL  += s
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        if name == "service" {
            if curServiceType.contains("AVTransport") && avControlURL.isEmpty {
                avControlURL = curControlURL
            }
            curServiceType = ""; curControlURL = ""
        }
        path.removeLast()
    }
}
