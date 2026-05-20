import Foundation
import Darwin

struct DLNADevice {
    let id: String
    let name: String
    let manufacturer: String
    let controlURL: URL
}

/// Discovers DLNA MediaRenderer devices on the local network via SSDP.
///
/// Older Samsung Smart TVs (AllShare / Screen Mirror era) respond to
/// `upnp:rootdevice` and `ssdp:all` but often NOT to `MediaRenderer:1`
/// alone.  We therefore send multiple M-SEARCH queries per cycle and
/// deduplicate by device UUID rather than the full USN so the same TV
/// doesn't get fetched multiple times.
final class DLNADiscovery {

    var onUpdate: (([DLNADevice]) -> Void)?

    private var running = false
    private var knownUUIDs: Set<String>     = []   // dedup across cycles
    private var knownDevices: [String: DLNADevice] = [:]
    private let queue = DispatchQueue(label: "com.iosmirror.dlna.discovery", qos: .utility)

    // ST values sent in each search cycle, in order.
    // `upnp:rootdevice` catches Samsung TVs that ignore MediaRenderer:1.
    // `ssdp:all` is a broad net for devices that only respond to that.
    // The Samsung-specific ST catches older AllShare firmware.
    private let searchTargets: [String] = [
        "upnp:rootdevice",
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:dial-multiscreen-org:service:dial:1",
        "urn:samsung.com:device:RemoteControlReceiver:1",
        "ssdp:all",
    ]

    func start() {
        guard !running else { return }
        running = true
        scheduleCycle()
    }

    func stop() {
        running = false
    }

    // MARK: - Discovery cycle

    private func scheduleCycle() {
        guard running else { return }
        queue.async { [weak self] in
            self?.performSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.scheduleCycle()
            }
        }
    }

    private func performSearch() {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port   = 0
        local.sin_addr   = in_addr(s_addr: 0)
        let bindOK = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { return }

        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))

        // Generous receive timeout — we send several queries and Samsung
        // devices can be slow to respond.
        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Fire all search targets with a short gap so we don't flood.
        for st in searchTargets {
            sendMSearch(sock: sock, st: st)
            Thread.sleep(forTimeInterval: 0.15)
        }

        var seen = Set<String>()   // per-cycle location dedup
        var buf  = [UInt8](repeating: 0, count: 8192)
        while running {
            let n = recv(sock, &buf, buf.count - 1, 0)
            guard n > 0 else { break }
            buf[Int(n)] = 0
            let response = String(bytes: buf[0..<Int(n)], encoding: .utf8) ?? ""
            handleResponse(response, seenLocations: &seen)
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

    // MARK: - Response parsing

    private func handleResponse(_ response: String, seenLocations: inout Set<String>) {
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

        // Deduplicate by device UUID, not full USN.
        // Samsung TVs send the same LOCATION for many ST variants:
        //   uuid:AAAA::upnp:rootdevice
        //   uuid:AAAA::urn:samsung.com:device:MainTVServer2:1
        // We only want to fetch the description once per unique UUID.
        let uuid = deviceUUID(from: rawUSN)
        guard !seenLocations.contains(loc), !knownUUIDs.contains(uuid) else { return }
        seenLocations.insert(loc)
        knownUUIDs.insert(uuid)

        guard let url = URL(string: loc) else { return }
        fetchDescription(from: url, id: uuid)
    }

    /// Extracts the bare UUID from a USN like "uuid:XXXX::urn:..." → "XXXX".
    private func deviceUUID(from usn: String) -> String {
        let s = usn.hasPrefix("uuid:") ? String(usn.dropFirst(5)) : usn
        return s.components(separatedBy: "::").first ?? s
    }

    // MARK: - Device description fetch

    private func fetchDescription(from url: URL, id: String) {
        let sem = DispatchSemaphore(value: 0)
        var responseData: Data?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            responseData = data
            sem.signal()
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

// MARK: - UPnP device description XML parser

/// Walks the entire device description tree (including nested sub-devices)
/// looking for an AVTransport service.  Samsung TVs embed their MediaRenderer
/// and AVTransport service inside a child device under a Samsung-proprietary
/// root device, so we must search recursively.
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
        self.xml     = xml
        self.baseURL = baseURL
        self.id      = id
    }

    func parse() -> DLNADevice? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        // Must have found at least a name and an AVTransport endpoint.
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
                attributes: [String: String]) {
        path.append(name)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let tag = path.last else { return }
        switch tag {
        // Capture the root device's friendly name only (first occurrence).
        case "friendlyName":
            if friendlyName.isEmpty { friendlyName += s }
        case "manufacturer":
            if manufacturer.isEmpty { manufacturer += s }
        case "serviceType":
            curServiceType += s
        case "controlURL":
            curControlURL += s
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement name: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        if name == "service" {
            // Accept the first AVTransport controlURL found anywhere in the tree.
            if curServiceType.contains("AVTransport") && avControlURL.isEmpty {
                avControlURL = curControlURL
            }
            curServiceType = ""
            curControlURL  = ""
        }
        path.removeLast()
    }
}
