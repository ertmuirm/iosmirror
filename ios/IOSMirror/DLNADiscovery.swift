import Foundation
import Darwin
import Network

struct DLNADevice {
    let id: String
    let name: String
    let manufacturer: String
    let controlURL: URL
}

/// Discovers DLNA MediaRenderer devices via SSDP and Samsung TVs via mDNS.
///
/// Three-pronged approach:
///   1. Active M-SEARCH: sends UDP multicast queries, socket explicitly bound
///      to the WiFi interface so multicast goes out the right NIC.
///   2. Passive NOTIFY listener: joins the SSDP multicast group on port 1900
///      and receives unsolicited alive/byebye messages that Samsung TVs
///      broadcast periodically — works even if M-SEARCH responses are blocked.
///   3. NetServiceBrowser for _samsungtvpresence._tcp (mDNS): reliably
///      triggers iOS Local Network permission and catches Samsung SmartHub
///      TVs that don't respond to SSDP queries.
final class DLNADiscovery {

    var onUpdate: (([DLNADevice]) -> Void)?
    var onDebug:  ((String) -> Void)?          // wired to MirrorBridge onDebug

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

    private let samsungDLNAProbes: [(port: Int, path: String)] = [
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

        // 1. Active M-SEARCH cycle
        scheduleMSearchCycle()

        // 2. Passive NOTIFY listener on the multicast group (port 1900)
        listenerQueue.async { [weak self] in self?.runNotifyListener() }

        // 3. Samsung mDNS browser (must run on a thread with RunLoop)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let b = SamsungMDNSBrowser()
            b.onDeviceFound = { [weak self] host in
                self?.onDebug?("dlna_mdns_found:\(host)")
                self?.searchQueue.async { self?.probeSamsungTV(host: host) }
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
            onDebug?("dlna_no_wifi_ip")
            return
        }
        onDebug?("dlna_search_start:\(localIPStr)")

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { onDebug?("dlna_socket_failed"); return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind explicitly to WiFi IP so multicast doesn't route through cellular.
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
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF,
                   &mcastIf, socklen_t(MemoryLayout<in_addr>.size))

        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))

        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var sentCount = 0
        for st in searchTargets {
            if sendMSearch(sock: sock, st: st) { sentCount += 1 }
            Thread.sleep(forTimeInterval: 0.15)
        }
        onDebug?("dlna_search_sent:\(sentCount)")

        var seen = Set<String>()
        var buf  = [UInt8](repeating: 0, count: 8192)
        var responseCount = 0
        while running {
            let n = recv(sock, &buf, buf.count - 1, 0)
            if n <= 0 { break }   // timeout (EAGAIN) or closed
            buf[Int(n)] = 0
            let msg = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            responseCount += 1
            handleSSDPMessage(msg, localSeen: &seen, source: "msearch")
        }
        onDebug?("dlna_search_responses:\(responseCount)")
    }

    @discardableResult
    private func sendMSearch(sock: Int32, st: String) -> Bool {
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: \(st)\r\n\r\n"
        guard let data = msg.data(using: .utf8) else { return false }
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port   = UInt16(1900).bigEndian
        dest.sin_addr   = in_addr(s_addr: inet_addr("239.255.255.250"))
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, bytes.baseAddress, bytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    // MARK: - Passive NOTIFY listener

    /// Listens on the SSDP multicast group (239.255.255.250:1900) for
    /// unsolicited ssdp:alive NOTIFY messages.  Samsung TVs broadcast
    /// these periodically (~every 30 min) and immediately on power-on.
    private func runNotifyListener() {
        guard let localIPStr = HLSStreamServer.shared.detectLocalIP() else { return }
        onDebug?("dlna_notify_listener_starting")

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Must bind to INADDR_ANY:1900 to receive multicast NOTIFY messages.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = UInt16(1900).bigEndian
        local.sin_addr   = in_addr(s_addr: 0)
        guard withUnsafePointer(to: &local, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }) else { onDebug?("dlna_notify_bind_failed:\(errno)"); return }

        // Join the SSDP multicast group on the WiFi interface.
        var mreq = ip_mreq()
        mreq.imr_multiaddr = in_addr(s_addr: inet_addr("239.255.255.250"))
        mreq.imr_interface = in_addr(s_addr: inet_addr(localIPStr))
        let joined = setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                                &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
        onDebug?("dlna_notify_listener_ready:joined=\(joined)")

        // Short receive timeout so we can check the `running` flag.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf  = [UInt8](repeating: 0, count: 8192)
        var seen = Set<String>()        // grows for the lifetime of the listener
        while running {
            let n = recv(sock, &buf, buf.count - 1, 0)
            if n <= 0 { continue }     // timeout — loop again, check `running`
            buf[Int(n)] = 0
            let msg = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            // Only process ssdp:alive NOTIFY, not byebye or M-SEARCH
            if msg.contains("NTS: ssdp:alive") || msg.contains("NTS:ssdp:alive") {
                handleSSDPMessage(msg, localSeen: &seen, source: "notify")
            }
        }
        // Leave multicast group cleanly
        setsockopt(sock, IPPROTO_IP, IP_DROP_MEMBERSHIP,
                   &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
    }

    // MARK: - Samsung mDNS probe

    private func probeSamsungTV(host: String) {
        let id = "samsung-\(host)"
        guard !knownUUIDs.contains(id) else { return }
        knownUUIDs.insert(id)
        onDebug?("dlna_probing_samsung:\(host)")

        for (port, path) in samsungDLNAProbes {
            guard let url = URL(string: "http://\(host):\(port)\(path)") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 3)
            req.httpMethod = "GET"
            let sem = DispatchSemaphore(value: 0)
            var hit: (Data, URL)?
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                if let data, (resp as? HTTPURLResponse)?.statusCode == 200 { hit = (data, url) }
                sem.signal()
            }.resume()
            sem.wait()

            if let (data, baseURL) = hit,
               let xml = String(data: data, encoding: .utf8) {
                onDebug?("dlna_samsung_desc_found:\(host):\(port)\(path)")
                if let device = DescriptionParser(xml: xml, baseURL: baseURL, id: id).parse() {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.knownDevices[id] = device
                        self.onUpdate?(Array(self.knownDevices.values))
                    }
                    return
                } else {
                    onDebug?("dlna_samsung_no_avt:\(host):\(port)\(path)")
                }
            }
        }
        onDebug?("dlna_samsung_probe_done:\(host):no_avt_found")
    }

    // MARK: - SSDP message handling (shared by M-SEARCH and NOTIFY)

    private func handleSSDPMessage(_ msg: String, localSeen: inout Set<String>, source: String) {
        var location: String?
        var usn: String?
        for line in msg.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("usn:") {
                usn = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let loc = location, let rawUSN = usn else { return }

        let uuid = deviceUUID(from: rawUSN)
        guard !localSeen.contains(loc), !knownUUIDs.contains(uuid) else { return }
        localSeen.insert(loc)
        knownUUIDs.insert(uuid)

        onDebug?("dlna_\(source)_hit:\(uuid.prefix(8)):\(loc)")
        guard let url = URL(string: loc) else { return }
        fetchAndRegister(from: url, id: uuid)
    }

    private func deviceUUID(from usn: String) -> String {
        let s = usn.hasPrefix("uuid:") ? String(usn.dropFirst(5)) : usn
        return s.components(separatedBy: "::").first ?? s
    }

    // MARK: - Device description fetch

    private func fetchAndRegister(from url: URL, id: String) {
        let sem = DispatchSemaphore(value: 0)
        var responseData: Data?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            responseData = data; sem.signal()
        }.resume()
        sem.wait()
        guard let data = responseData,
              let xml = String(data: data, encoding: .utf8)
        else { onDebug?("dlna_desc_fetch_failed:\(url.host ?? "?")"); return }

        if let device = DescriptionParser(xml: xml, baseURL: url, id: id).parse() {
            onDebug?("dlna_device_added:\(device.name)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.knownDevices[device.id] = device
                self.onUpdate?(Array(self.knownDevices.values))
            }
        } else {
            onDebug?("dlna_desc_no_avt:\(url.host ?? "?"):\(url.port ?? 0)")
        }
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

    func stop() {
        browser.stop()
        pending.forEach { $0.stop() }
        pending = []
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService, moreComing: Bool) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
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
                return getnameinfo(addr, socklen_t(data.count),
                                   &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0
            }
            if ok { return String(cString: host) }
        }
        return nil
    }
}

// MARK: - UPnP device description XML parser

private final class DescriptionParser: NSObject, XMLParserDelegate {
    private let xml: String
    private let baseURL: URL
    private let id: String

    private var path:          [String] = []
    private var friendlyName   = ""
    private var manufacturer   = ""
    private var avControlURL   = ""
    private var curServiceType = ""
    private var curControlURL  = ""

    init(xml: String, baseURL: URL, id: String) {
        self.xml = xml; self.baseURL = baseURL; self.id = id
    }

    func parse() -> DLNADevice? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        guard !friendlyName.isEmpty, !avControlURL.isEmpty else { return nil }
        guard let controlURL = URL(string: avControlURL, relativeTo: baseURL)?.absoluteURL
        else { return nil }
        return DLNADevice(
            id:           id,
            name:         friendlyName,
            manufacturer: manufacturer.isEmpty ? "DLNA" : manufacturer,
            controlURL:   controlURL
        )
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
