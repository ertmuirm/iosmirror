import Foundation

/// Controls a DLNA MediaRenderer via UPnP AV Transport SOAP commands.
final class DLNASession {

    private let controlURL: URL
    private let avtNS = "urn:schemas-upnp-org:service:AVTransport:1"

    init(controlURL: URL) {
        self.controlURL = controlURL
    }

    // MARK: - Public API

    func loadAndPlay(_ streamURL: URL, completion: @escaping (Error?) -> Void) {
        let setBody = """
        <u:SetAVTransportURI xmlns:u="\(avtNS)">
          <InstanceID>0</InstanceID>
          <CurrentURI>\(streamURL.absoluteString)</CurrentURI>
          <CurrentURIMetaData></CurrentURIMetaData>
        </u:SetAVTransportURI>
        """
        soap(action: "SetAVTransportURI", body: setBody) { [weak self] err in
            if let err { completion(err); return }
            guard let self else { return }
            let playBody = """
            <u:Play xmlns:u="\(self.avtNS)">
              <InstanceID>0</InstanceID>
              <Speed>1</Speed>
            </u:Play>
            """
            self.soap(action: "Play", body: playBody, completion: completion)
        }
    }

    func stop(completion: @escaping (Error?) -> Void) {
        let body = """
        <u:Stop xmlns:u="\(avtNS)">
          <InstanceID>0</InstanceID>
        </u:Stop>
        """
        soap(action: "Stop", body: body, completion: completion)
    }

    // MARK: - SOAP request

    private func soap(action: String, body: String, completion: @escaping (Error?) -> Void) {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>\(body)</s:Body>
        </s:Envelope>
        """
        guard let data = envelope.data(using: .utf8) else {
            completion(NSError(domain: "DLNASession", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Envelope encoding failed"]))
            return
        }
        var req = URLRequest(url: controlURL, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(avtNS)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { completion(err); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                completion(nil)
            } else {
                completion(NSError(domain: "DLNASession", code: code,
                                   userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]))
            }
        }.resume()
    }
}
