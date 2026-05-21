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
/// Uses a single UDP socket bound to 0.0.0.0:1900 that joins the SSDP
/// multicast group once.  The same socket both sends M-SEARCH bursts every
/// 15 s and receives NOTIFY announcements and 200-OK unicast replies.
/// This avoids the EHOSTUNREACH/double-join problem that arises when two
/// sockets try to join 239.255.255.250 on the same interface.
final class DLNADiscovery {

    var onUpdate: (([DLNADevice]) -> Void)?
    var onDebug:  ((String) -> Void)?

    private var running = false
    private var knownUUIDs:   Set<String>          = []
    private var knownDevices: [String: DLNADevice] = [:]

    // Serial queue for the SSDP socket loop.
    private let ssdpQueue  = DispatchQueue(label: "com.iosmirror.dlna.ssdp",  qos: .utility)
    // Concurrent queue for HTTP description fetches so they don't stall recv.
    private let fetchQueue = DispatchQueue(label: "com.iosmirror.dlna.fetch",  qos: .utility,
                                           attributes: .concurrent)

    private var mdnsBrowser: SamsungMDNSBrowser?

    private let searchTargets: [String] = [
        "upnp:rootdevice",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:dial-multiscreen-org:service:dial:1",
        "urn:samsung.com:device:RemoteControlReceiver:1",
        "ssdp:all",
    ]

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
        ssdpQueue.async { [weak self] in self?.runDiscovery() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let b = SamsungMDNSBrowser()
            b.onDeviceFound = { [weak self] host in
                self?.onDebug?("dlna_mdns_found:\(host)")
                self?.fetchQueue.async {
                    self?.probeSamsungDMR(host: host, port: 7676,
                                         id: "samsung-\(host)", name: nil, mfr: nil)
                }
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

    // MARK: - Single-socket SSDP discovery

    private func runDiscovery() {
        guard let localIPStr = HLSStreamServer.shared.detectLocalIP() else {
            onDebug?("dlna_no_wifi_ip"); return
        }
        onDebug?("dlna_discovery_start:\(localIPStr)")

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { onDebug?("dlna_socket_failed:\(errno)"); return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to INADDR_ANY:1900 so we receive both multicast NOTIFY and
        // unicast 200-OK replies (some devices reply to port 1900, not our
        // ephemeral source port).
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = UInt16(1900).bigEndian
        local.sin_addr   = in_addr(s_addr: 0)
        guard withUnsafePointer(to: &local, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }) else { onDebug?("dlna_bind_failed:\(errno)"); return }

        // One IP_ADD_MEMBERSHIP establishes both the kernel multicast route
        // (required for sendto to 239.255.255.250) and multicast receive.
        var mreq = ip_mreq()
        mreq.imr_multiaddr = in_addr(s_addr: inet_addr("239.255.255.250"))
        mreq.imr_interface = in_addr(s_addr: inet_addr(localIPStr))
        let joined = setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                                &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0

        // IP_BOUND_IF (Darwin option 25) locks ALL socket I/O to a specific
        // interface by index, overriding the routing table.  This is more
        // reliable than IP_MULTICAST_IF for forcing multicast sends through
        // WiFi on iOS when multiple interfaces are active.
        var en0Index = if_nametoindex("en0")
        let boundOk = setsockopt(sock, IPPROTO_IP, 25 /* IP_BOUND_IF */,
                                 &en0Index, socklen_t(MemoryLayout<UInt32>.size)) == 0

        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))

        onDebug?("dlna_ready:joined=\(joined):bound=\(boundOk):ifindex=\(en0Index)")

        // 1-second receive timeout lets the loop also handle periodic M-SEARCH.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var seen     = Set<String>()
        var buf      = [UInt8](repeating: 0, count: 8192)
        var lastSearch: Date = .distantPast

        while running {
            // Send M-SEARCH burst every 15 s.
            if Date().timeIntervalSince(lastSearch) >= 15 {
                var sent = 0
                for st in searchTargets {
                    if sendMSearch(sock: sock, st: st) { sent += 1 }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                onDebug?("dlna_search_sent:\(sent)")
                lastSearch = Date()
            }

            let n = recv(sock, &buf, buf.count - 1, 0)
            guard n > 0 else { continue }
            buf[Int(n)] = 0
            let msg = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            let up  = msg.uppercased()
            if up.hasPrefix("NOTIFY") || up.hasPrefix("HTTP/1.1 200") || msg.contains("ssdp:alive") {
                handleSSDPMessage(msg, localSeen: &seen)
            }
        }

        setsockopt(sock, IPPROTO_IP, IP_DROP_MEMBERSHIP,
                   &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
    }

    private func sendMSearch(sock: Int32, st: String) -> Bool {
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 5\r\nST: \(st)\r\n\r\n"
        var bytes = Array(msg.utf8)
        var dest  = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port   = UInt16(1900).bigEndian
        dest.sin_addr   = in_addr(s_addr: inet_addr("239.255.255.250"))
        let sent: Int = withUnsafePointer(to: &dest) { ptr -> Int in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                sendto(sock, &bytes, bytes.count, 0, sp,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 { onDebug?("dlna_sendto_errno:\(errno)") }
        return sent == bytes.count
    }

    // MARK: - SSDP message handling

    private func handleSSDPMessage(_ msg: String, localSeen: inout Set<String>) {
        let lines = msg.components(separatedBy: "\r\n").flatMap {
            $0.components(separatedBy: "\n")
        }
        var location: String?
        var usn: String?
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("usn:") {
                usn = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }

        let firstLine = lines.first ?? ""
        onDebug?("dlna_pkt:\(firstLine.prefix(50)):loc=\(location ?? "nil")")

        guard let loc = location else { return }
        let rawUSN = usn ?? loc
        let uuid   = deviceUUID(from: rawUSN)
        guard !localSeen.contains(loc), !knownUUIDs.contains(uuid) else { return }
        localSeen.insert(loc)
        knownUUIDs.insert(uuid)
        onDebug?("dlna_hit:\(uuid.prefix(8)):\(loc)")
        guard let url = URL(string: loc) else {
            onDebug?("dlna_bad_url:\(loc)"); return
        }
        fetchQueue.async { [weak self] in self?.fetchAndRegister(from: url, id: uuid) }
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
            onDebug?("dlna_fetch_failed:\(url.host ?? "?")"); return
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
            onDebug?("dlna_samsung_no_avt:\(label):probing_dmr")
            probeSamsungDMR(host: host, port: url.port ?? 7676, id: id,
                            name: result.friendlyName, mfr: result.manufacturer)
        } else {
            onDebug?("dlna_rejected:\(label):no_avt")
        }
    }

    // MARK: - Samsung MediaRenderer probe

    private func probeSamsungDMR(host: String, port: Int, id: String,
                                  name: String?, mfr: String?) {
        guard knownDevices[id] == nil else { return }

        for (probePort, probePath) in samsungDMRProbes {
            guard let url = URL(string: "http://\(host):\(probePort)\(probePath)") else { continue }
            let req = URLRequest(url: url, timeoutInterval: 3)
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
                }
                onDebug?("dlna_samsung_probe_no_avt:\(host):\(probePort)\(probePath)")
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

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        pending.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let ip = ipv4Address(from: sender) { onDeviceFound?(ip) }
        pending.removeAll { $0 === sender }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {}

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
    let deviceType:   String
    let controlURL:   URL?

    var shortType: String { deviceType.components(separatedBy: ":").last ?? deviceType }

    var isSamsung: Bool {
        manufacturer.lowercased().contains("samsung") ||
        deviceType.lowercased().contains("samsung")
    }
}

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
            let p = XMLParser(data: data); p.delegate = self; p.parse()
        }
        let controlURL: URL? = avControlURL.isEmpty ? nil :
            URL(string: avControlURL, relativeTo: baseURL)?.absoluteURL
        return ParseResult(friendlyName: friendlyName,
                           manufacturer: manufacturer.isEmpty ? "DLNA" : manufacturer,
                           deviceType:   deviceType,
                           controlURL:   controlURL)
    }

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
