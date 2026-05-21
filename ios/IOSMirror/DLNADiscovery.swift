import Foundation
import Darwin
import Network

struct DLNADevice {
    let id: String
    let name: String
    let manufacturer: String
    let controlURL: URL
}

/// Discovers DLNA MediaRenderer devices via three paths that work without
/// the com.apple.developer.networking.multicast entitlement:
///
///  1. Passive SSDP NOTIFY listener on port 1900 (receives broadcasts; no send needed).
///  2. NWBrowser for _samsungtvpresence._tcp and _amzn-wplay._tcp mDNS services.
///     NWBrowser uses the system mDNSResponder daemon which is exempt from the
///     multicast entitlement restriction.
///  3. ARP-cache sweep: reads the kernel ARP table (sysctl RTF_LLINFO) to find
///     IPs of every device on the LAN, then HTTP-probes Samsung DLNA ports on
///     each. This is pure TCP unicast — no multicast or broadcast required.
///
/// Active M-SEARCH is also attempted but will fail with EHOSTUNREACH on
/// iOS 14.5+ without the entitlement; the code is retained for the day
/// the entitlement is added.
final class DLNADiscovery {

    var onUpdate: (([DLNADevice]) -> Void)?
    var onDebug:  ((String) -> Void)?

    private var running = false
    private var knownUUIDs:   Set<String>          = []
    private var knownDevices: [String: DLNADevice] = [:]

    private let ssdpQueue  = DispatchQueue(label: "com.iosmirror.dlna.ssdp",  qos: .utility)
    private let fetchQueue = DispatchQueue(label: "com.iosmirror.dlna.fetch",  qos: .utility,
                                           attributes: .concurrent)

    private var mdnsBrowser: SamsungNWBrowser?

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
        (7676,  "/upnp/0/getDescription"),
        (7676,  "/"),
        (52235, "/dmr/SamsungMRDesc.xml"),
        (52235, "/MediaRenderer.xml"),
        (52235, "/"),
        (55001, "/MainTVServer2desc.xml"),
        (8080,  "/upnp/0/getDescription"),
        (8080,  "/samsungMobile/DeviceDesc.xml"),
        (8080,  "/"),
    ]

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true

        // Path 1: passive SSDP socket + attempted M-SEARCH
        ssdpQueue.async { [weak self] in self?.runDiscovery() }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Path 2: NWBrowser mDNS (works without entitlement via mDNSResponder)
            let b = SamsungNWBrowser()
            b.onDeviceFound = { [weak self] host in
                self?.onDebug?("dlna_mdns_found:\(host)")
                self?.fetchQueue.async {
                    self?.probeSamsungDMR(host: host, port: 7676,
                                         id: "mdns-\(host)", name: nil, mfr: nil)
                }
            }
            b.start()
            self.mdnsBrowser = b
        }

        // Path 3: ARP sweep — runs once at startup then every 30 s
        fetchQueue.async { [weak self] in self?.sweepARPHosts() }
    }

    func stop() {
        running = false
        DispatchQueue.main.async { [weak self] in
            self?.mdnsBrowser?.stop()
            self?.mdnsBrowser = nil
        }
    }

    // MARK: - Path 1: SSDP socket (passive receive + attempted M-SEARCH)

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

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = UInt16(1900).bigEndian
        local.sin_addr   = in_addr(s_addr: 0)
        guard withUnsafePointer(to: &local, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }) else { onDebug?("dlna_bind_failed:\(errno)"); return }

        var mreq = ip_mreq()
        mreq.imr_multiaddr = in_addr(s_addr: inet_addr("239.255.255.250"))
        mreq.imr_interface = in_addr(s_addr: inet_addr(localIPStr))
        let joined = setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                                &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0

        var en0Index = if_nametoindex("en0")
        let boundOk = setsockopt(sock, IPPROTO_IP, 25 /* IP_BOUND_IF */,
                                 &en0Index, socklen_t(MemoryLayout<UInt32>.size)) == 0

        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))

        onDebug?("dlna_ready:joined=\(joined):bound=\(boundOk)")

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var seen       = Set<String>()
        var buf        = [UInt8](repeating: 0, count: 8192)
        var lastSearch: Date = .distantPast

        while running {
            // Attempt M-SEARCH — will fail with EHOSTUNREACH without the
            // com.apple.developer.networking.multicast entitlement, but we
            // keep it so it works automatically once the entitlement is added.
            if Date().timeIntervalSince(lastSearch) >= 15 {
                var sent = 0
                for st in searchTargets {
                    if sendMSearch(sock: sock, st: st) { sent += 1 }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                if sent > 0 { onDebug?("dlna_search_sent:\(sent)") }
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
        return sent == bytes.count
    }

    // MARK: - Path 3: ARP cache sweep

    /// Reads the kernel ARP cache, sends unicast SSDP M-SEARCH to each IP,
    /// then falls back to Samsung HTTP port probes.  Repeats every 30 s.
    private func sweepARPHosts() {
        guard running else { return }
        let hosts = readARPTable()
        onDebug?("dlna_arp_sweep:\(hosts.count)_hosts")

        // Phase 1: unicast SSDP — sends M-SEARCH directly to each IP:1900 and
        // collects responses. Unicast UDP to a specific IP needs no entitlement.
        unicastSSDPScan(hosts: hosts)

        // Phase 2: Samsung HTTP port probes for TVs that don't respond to SSDP.
        // Dispatch each host as a separate concurrent task (not sequential blocking).
        for ip in hosts {
            guard running else { return }
            fetchQueue.async { [weak self] in
                self?.probeSamsungDMR(host: ip, port: 7676, id: "arp-\(ip)", name: nil, mfr: nil)
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.sweepARPHosts()
        }
    }

    /// Sends unicast UDP M-SEARCH to port 1900 on every ARP host, then waits
    /// up to 5 s for UPnP responses.  Unicast UDP to a specific IP does not
    /// require the com.apple.developer.networking.multicast entitlement.
    private func unicastSSDPScan(hosts: [String]) {
        guard !hosts.isEmpty else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = 0
        local.sin_addr   = in_addr(s_addr: INADDR_ANY)
        guard withUnsafePointer(to: &local, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }) else { onDebug?("dlna_unicast_bind_failed:\(errno)"); return }

        // Send M-SEARCH to every host quickly before waiting for replies.
        for ip in hosts {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: \(ip):1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: ssdp:all\r\n\r\n"
            var bytes = Array(msg.utf8)
            var dest  = sockaddr_in()
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port   = UInt16(1900).bigEndian
            dest.sin_addr   = in_addr(s_addr: inet_addr(ip))
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    sendto(sock, &bytes, bytes.count, 0, sp,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        onDebug?("dlna_unicast_scan:\(hosts.count)")

        // Collect responses for up to 5 s; use a short per-recv timeout so we
        // can re-check the deadline and running flag between each call.
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        var seen = Set<String>()
        var buf  = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && running {
            let n = recv(sock, &buf, buf.count - 1, 0)
            guard n > 0 else { continue }
            buf[Int(n)] = 0
            let msg = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            let up  = msg.uppercased()
            if up.hasPrefix("HTTP/1.1 200") || msg.contains("ssdp:alive") {
                handleSSDPMessage(msg, localSeen: &seen)
            }
        }
    }

    /// Reads the kernel ARP cache via sysctl.  Returns IPv4 addresses of all
    /// neighbours visible on the local network — no multicast, no broadcast,
    /// no special entitlement required.
    private func readARPTable() -> [String] {
        // CTL_NET / PF_ROUTE / 0 / AF_INET / NET_RT_FLAGS / RTF_LLINFO
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buf, &needed, nil, 0) == 0 else { return [] }

        var ips: [String] = []
        var offset = 0
        let rtmSize = MemoryLayout<rt_msghdr_ios>.size

        while offset + rtmSize <= needed {
            // rtm_msglen is the first u_short (little-endian on ARM)
            let msgLen = Int(buf[offset]) | (Int(buf[offset + 1]) << 8)
            guard msgLen >= rtmSize, offset + msgLen <= needed else { break }

            // sockaddr_inarp (layout-compatible with sockaddr_in for the IP part)
            // immediately follows rt_msghdr.
            // Offsets within sockaddr: [0]=sa_len, [1]=sa_family, [2-3]=sin_port,
            //                          [4-7]=sin_addr (network byte order = big-endian)
            let saOff = offset + rtmSize
            if saOff + 8 <= needed, buf[saOff + 1] == UInt8(AF_INET) {
                let ip = "\(buf[saOff+4]).\(buf[saOff+5]).\(buf[saOff+6]).\(buf[saOff+7])"
                if buf[saOff + 4] != 0 && !ips.contains(ip) {
                    ips.append(ip)
                }
            }
            offset += msgLen
        }
        return ips
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
        var req = URLRequest(url: url, timeoutInterval: 5)
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in data = d; sem.signal() }.resume()
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
        var gotAnyHTTPResponse = false
        for (probePort, probePath) in samsungDMRProbes {
            guard running else { return }
            guard let url = URL(string: "http://\(host):\(probePort)\(probePath)") else { continue }
            let req = URLRequest(url: url, timeoutInterval: 2)
            let sem = DispatchSemaphore(value: 0)
            var hit: (Data, URL)?
            URLSession.shared.dataTask(with: req) { d, resp, _ in
                if resp != nil { gotAnyHTTPResponse = true }
                if let d, (resp as? HTTPURLResponse)?.statusCode == 200 { hit = (d, url) }
                sem.signal()
            }.resume()
            sem.wait()
            guard let (data, baseURL) = hit,
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let result = DescriptionParser(xml: xml, baseURL: baseURL, id: id).parseResult()
            if let controlURL = result.controlURL {
                let displayName = name ?? result.friendlyName
                let displayMfr  = mfr  ?? result.manufacturer
                onDebug?("dlna_samsung_added:\(displayName):\(host):\(probePort)\(probePath)")
                let device = DLNADevice(id: id, name: displayName,
                                       manufacturer: displayMfr, controlURL: controlURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.knownDevices[id] = device
                    self.onUpdate?(Array(self.knownDevices.values))
                }
                return
            }
        }
        // Only log when the host responded over HTTP but had no DLNA AVTransport.
        if gotAnyHTTPResponse { onDebug?("dlna_probe_no_avt:\(host)") }
    }
}

// MARK: - NWBrowser-based Samsung TV mDNS discovery

/// Uses NWBrowser (backed by the system mDNSResponder daemon) to browse for
/// Samsung TV mDNS services.  This works without the multicast entitlement
/// because the system daemon handles all multicast sends on the app's behalf.
private final class SamsungNWBrowser {
    var onDeviceFound: ((String) -> Void)?

    private var browsers:    [NWBrowser]    = []
    private var connections: [NWConnection] = []

    private let serviceTypes = [
        "_samsungtvpresence._tcp",
        "_samsungsmarthome._tcp",
        "_amzn-wplay._tcp",
    ]

    func start() {
        for type in serviceTypes {
            let b = NWBrowser(
                for: .bonjour(type: type, domain: "local"),
                using: NWParameters()
            )
            b.browseResultsChangedHandler = { [weak self] _, changes in
                for change in changes {
                    if case .added(let result) = change {
                        self?.resolve(endpoint: result.endpoint)
                    }
                }
            }
            b.stateUpdateHandler = { _ in }
            b.start(queue: .main)
            browsers.append(b)
        }
    }

    func stop() {
        browsers.forEach    { $0.cancel() }
        connections.forEach { $0.cancel() }
        browsers.removeAll()
        connections.removeAll()
    }

    private func resolve(endpoint: NWEndpoint) {
        // Open a TCP connection to the Bonjour endpoint — this triggers mDNS
        // resolution through the system daemon and gives us the remote IP once ready.
        let conn = NWConnection(to: endpoint, using: .tcp)
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path   = conn.currentPath,
                   case .hostPort(let host, _) = path.remoteEndpoint {
                    let ip = "\(host)"   // NWEndpoint.Host is CustomStringConvertible
                    if !ip.isEmpty { self?.onDeviceFound?(ip) }
                }
                conn.cancel()
            case .failed, .cancelled:
                self?.connections.removeAll { $0 === conn }
            default: break
            }
        }
        conn.start(queue: .main)
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
