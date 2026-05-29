import Foundation

/// Advertises the server over Bonjour as `_sandboxserver._tcp` so the MCP bridge (and any
/// `NWBrowser`) can discover the device on the LAN. Only started after `start()` and only in
/// `.localNetwork` mode. TXT carries enough for a client to decide whether/how to connect.
final class BonjourAdvertiser: NSObject, @unchecked Sendable {
    private var service: NetService?

    func start(port: Int, name: String, txt: [String: String]) {
        let record = txt.reduce(into: [String: Data]()) { $0[$1.key] = Data($1.value.utf8) }
        // NetService must be published on a thread with an active run loop.
        DispatchQueue.main.async {
            let service = NetService(domain: "local.", type: "_sandboxserver._tcp.", name: name, port: Int32(port))
            service.setTXTRecord(NetService.data(fromTXTRecord: record))
            service.publish()
            self.service = service
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.service?.stop()
            self.service = nil
        }
    }
}
