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
/// Two-pronged approach:
///   1. SSDP M-SEARCH with multiple ST values, socket explicitly bound to the
///      WiFi interface so multicast goes out the right NIC (not cellular).
///   2. NetServiceBrowser for _samsungtvpresence._tcp, which reliably triggers
///      iOS Local-Network permission and catches Samsung SmartHub TVs that
///      don't respond to standard MediaRenderer:1 queries.
final class DLNADiscovery {

    var onUpdate: (([DLNADevice]) -> Void)?

    private var running = false
    private var knownUUIDs:   Set<String>          = []
    private var knownDevices: [String: DLNADevice] = [:]
    private let queue = DispatchQueue(label: "com.iosmirror.dlna.discovery", qos: .utility)

    private var mdnsBrowser: SamsungMDNSBrowser?

    // ST values sent each cycle.  Samsung SmartHub TVs often only respond to
    // upnp:rootdevice and the Samsung-specific ST, not MediaRenderer:1.
    private let searchTargets: [String] = [
        "upnp:rootdevice",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:dial-multiscreen-org:service:dial:1",
        "urn:samsung.com:device:RemoteControlReceiver:1",
        "ssdp:all",
    ]

    // Paths probed when a Samsung TV is found via mDNS but not via SSDP.
    private let samsungDLNAProbes: [(port: Int, path: String)] = [
        (7676,  "/dmr/SamsungMRDesc.xml"),
        (7676,  "/MediaRenderer.xml"),
        (52235, "/dmr/SamsungMRDesc.xml"),
        (52235, "/MediaRenderer.xml"),
        (55001, "/MainTVServer2desc.xml"),
        (7676,  "/"),                   // some models serve description at root
    ]

    func start() {
        guard !running else { return }
        running = true
        scheduleSSDPCycle()

        // NetServiceBrowser must run on a thread with a RunLoop (main is fine).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let b = SamsungMDNSBrowser()
            b.onDeviceFound = { [weak self] host in
                self?.queue.async { self?.probeSamsungTV(host: host) }
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

    // MARK: - SSDP cycle

    private func scheduleSSDPCycle() {
        guard running else { return }
        queue.async { [weak self] in
            self?.performSSDPSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.scheduleSSDPCycle()
            }
        }
    }

    private func performSSDPSearch() {
        // Bind explicitly to the WiFi interface so multicast doesn't leak
        // over cellular, which can't reach LAN devices.
        let localIPStr = HLSStreamServer.shared.detectLocalIP() ?? "0.0.0.0"

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = 0
        local.sin_addr   = in_addr(s_addr: inet_addr(localIPStr))
        let bindOK = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { return }

        // Force multicast out the WiFi interface.
        var mcastIf = in_addr(s_addr: inet_addr(localIPStr))
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF,
                   &mcastIf, socklen_t(MemoryLayout<in_addr>.size))

        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))

        // Generous timeout: we send 5 queries × 150 ms gap = 750 ms,
        // then wait up to 6 s for responses from slower Samsung TVs.
        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        for st in searchTargets {
            sendMSearch(sock: sock, st: st)
            Thread.sleep(forTimeInterval: 0.15)
        }

        var seen = Set<String>()
        var buf  = [UInt8](repeating: 0, count: 8192)
        while running {
            let n = recv(sock, &buf, buf.count - 1, 0)
            guard n > 0 else { break }
            buf[Int(n)] = 0
            let response = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            handleSSDPResponse(response, seen: &seen)
        }
    }

    private func sendMSearch(sock: Int32, st: String) {
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: \(st)\r\n\r\n"
        guard let data = msg.data(using: .utf8) else { return }
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port   = UInt16(1900).bigEndian
        dest.sin_addr   = in_addr(s_addr: inet_addr("239.255.255.250"))
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, bytes.baseAddress, bytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - SSDP response handling

    private func handleSSDPResponse(_ response: String, seen: inout Set<String>) {
        var location: String?
        var usn: String?
        for line in response.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                location = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("usn:") {
                usn = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let loc = location, let rawUSN = usn else { return }

        // Deduplicate by device UUID — Samsung TVs reply once per ST value,
        // all pointing to the same LOCATION.
        let uuid = deviceUUID(from: rawUSN)
        guard !seen.contains(loc), !knownUUIDs.contains(uuid) else { return }
        seen.insert(loc)
        knownUUIDs.insert(uuid)

        guard let url = URL(string: loc) else { return }
        fetchAndRegister(from: url, id: uuid)
    }

    private func deviceUUID(from usn: String) -> String {
        let s = usn.hasPrefix("uuid:") ? String(usn.dropFirst(5)) : usn
        return s.components(separatedBy: "::").first ?? s
    }

    // MARK: - Samsung mDNS probe

    /// Called when a Samsung TV is found via _samsungtvpresence._tcp mDNS.
    /// Older SmartHub TVs may not respond to SSDP at all, so we probe their
    /// well-known DLNA ports directly once we have their IP.
    private func probeSamsungTV(host: String) {
        let id = "samsung-\(host)"
        guard !knownUUIDs.contains(id) else { return }
        knownUUIDs.insert(id)

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
               let xml = String(data: data, encoding: .utf8),
               let device = DescriptionParser(xml: xml, baseURL: baseURL, id: id).parse() {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.knownDevices[id] = device
                    self.onUpdate?(Array(self.knownDevices.values))
                }
                return
            }
        }
    }

    // MARK: - Device description fetch (SSDP path)

    private func fetchAndRegister(from url: URL, id: String) {
        let sem = DispatchSemaphore(value: 0)
        var responseData: Data?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            responseData = data; sem.signal()
        }.resume()
        sem.wait()
        guard let data = responseData,
              let xml = String(data: data, encoding: .utf8),
              let device = DescriptionParser(xml: xml, baseURL: url, id: id).parse()
        else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.knownDevices[device.id] = device
            self.onUpdate?(Array(self.knownDevices.values))
        }
    }
}

// MARK: - Samsung SmartHub mDNS browser

/// Browses for _samsungtvpresence._tcp on the local network.
/// Using NetServiceBrowser is important on iOS 14+: it reliably triggers
/// the Local Network permission prompt, which in turn unblocks our SSDP
/// UDP multicast traffic as well.
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
                           didFind service: NetService,
                           moreComing: Bool) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let ip = ipv4Address(from: sender) { onDeviceFound?(ip) }
        pending.removeAll { $0 === sender }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        // mDNS browse unavailable — SSDP cycle is still running.
    }

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

/// Walks the entire device/sub-device tree looking for an AVTransport service.
/// Samsung SmartHub TVs embed MediaRenderer and AVTransport inside a child
/// device under a Samsung-proprietary root device type, so the whole tree
/// must be searched.
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

    func parser(_ parser: XMLParser,
                didStartElement name: String,
                namespaceURI: String?,
                qualifiedName: String?,
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

    func parser(_ parser: XMLParser,
                didEndElement name: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        if name == "service" {
            if curServiceType.contains("AVTransport") && avControlURL.isEmpty {
                avControlURL = curControlURL
            }
            curServiceType = ""; curControlURL = ""
        }
        path.removeLast()
    }
}
