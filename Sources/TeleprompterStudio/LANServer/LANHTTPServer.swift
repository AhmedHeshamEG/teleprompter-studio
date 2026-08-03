import CoreImage.CIFilterBuiltins
import Foundation
import Network
import Observation
import SwiftData
import UIKit

/// Local HTTP server built directly on Apple's `Network` framework — zero external
/// dependencies, so it stays xtool-compatible. Serves the LAN script-editing web page on
/// `http://<device-ip>:<port>`. Binds to the local interface only; toggleable from Settings.
@MainActor
@Observable
final class LANHTTPServer {
    private(set) var isRunning = false
    private(set) var port: Int = 8080
    private(set) var localAddress: String?
    private(set) var lastError: String?

    private var listener: NWListener?
    private var modelContainer: ModelContainer?
    private var connections: [ObjectIdentifier: LANConnection] = [:]

    func start(port: Int, modelContainer: ModelContainer) {
        guard !isRunning else { return }
        self.modelContainer = modelContainer
        self.port = port

        do {
            let parameters = NWParameters.tcp
            // Without this, restarting the server (toggle off/on, or relaunching the app while the
            // old listener's socket is still in TIME_WAIT) fails with "Address already in use" and
            // the laptop just sees a dead port.
            parameters.allowLocalEndpointReuse = true
            // NOT `acceptLocalOnly = true`: despite the name, that restricts the listener to
            // loopback/same-device connections only, which silently blocks every other device on
            // the LAN (the "not found" symptom from a laptop browser). The server is already
            // scoped to the local network by virtue of binding to the Wi-Fi interface's address
            // and requiring NSLocalNetworkUsageDescription; no extra restriction is needed here.
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                lastError = "Invalid port \(port)"
                return
            }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        // Wi-Fi can finish coming up after the listener does; re-resolve here so
                        // the address shown in Settings (and its QR code) isn't stale or blank.
                        self?.localAddress = Self.currentWiFiIPAddress()
                        self?.lastError = nil
                    case .failed(let error):
                        self?.lastError = error.localizedDescription
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            isRunning = true
            localAddress = Self.currentWiFiIPAddress()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    var serverURL: String? {
        guard isRunning, let localAddress else { return nil }
        return "http://\(localAddress):\(port)"
    }

    /// Renders `serverURL` as a QR code using Core Image's built-in generator (no external
    /// dependency needed).
    func qrCodeImage() -> UIImage? {
        guard let urlString = serverURL, let data = urlString.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func accept(_ nwConnection: NWConnection) {
        let lanConnection = LANConnection(connection: nwConnection) { [weak self] request in
            await self?.route(request) ?? .notFound()
        }
        connections[ObjectIdentifier(nwConnection)] = lanConnection
        lanConnection.start()
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        guard let modelContainer else { return .text("Server not ready", status: 500) }
        let path = request.path.components(separatedBy: "?").first ?? request.path

        if path == "/" || path == "/index.html" {
            let response = staticResource(name: "editor", ext: "html")
            // A bare "Not Found" on the home page is indistinguishable from "wrong address" or
            // "server isn't running" from the laptop's side. If the page asset is genuinely
            // missing, say so — and prove the server itself is reachable.
            guard response.status == 404 else { return response }
            return .text(
                "Teleprompter Studio LAN server is running, but its editor page wasn't found in the app bundle. "
                    + "Searched: \(Self.resourceRoots.map(\.lastPathComponent).joined(separator: ", ")).",
                contentType: "text/plain; charset=utf-8",
                status: 500
            )
        }
        if path == "/editor.css" { return staticResource(name: "editor", ext: "css") }
        if path == "/editor.js" { return staticResource(name: "editor", ext: "js") }
        if path == "/marked.min.js" { return sharedResource(name: "marked.min", ext: "js") }
        if path.hasPrefix("/katex/") {
            return sharedResource(subpath: path)
        }

        if path == "/api/scripts" {
            switch request.method {
            case "GET":
                return .json(ScriptWebAPI.listScripts(container: modelContainer))
            case "POST":
                let payload = decodeJSONObject(request.body)
                let title = payload["title"] as? String ?? ""
                let markdown = payload["bodyMarkdown"] as? String ?? ""
                return .json(ScriptWebAPI.createScript(title: title, markdown: markdown, container: modelContainer), status: 201)
            default:
                break
            }
        }

        if path.hasPrefix("/api/scripts/") {
            let id = String(path.dropFirst("/api/scripts/".count))
            switch request.method {
            case "GET":
                guard let json = ScriptWebAPI.getScript(id: id, container: modelContainer) else { return .notFound() }
                return .json(json)
            case "PUT", "POST":
                let payload = decodeJSONObject(request.body)
                guard let json = ScriptWebAPI.updateScript(
                    id: id,
                    title: payload["title"] as? String,
                    markdown: payload["bodyMarkdown"] as? String,
                    container: modelContainer
                ) else { return .notFound() }
                return .json(json)
            case "DELETE":
                return ScriptWebAPI.deleteScript(id: id, container: modelContainer) ? HTTPResponse(status: 204, statusText: "No Content") : .notFound()
            default:
                break
            }
        }

        return .notFound()
    }

    private func decodeJSONObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func staticResource(name: String, ext: String) -> HTTPResponse {
        guard let data = Self.resourceData(name: name, ext: ext) else { return .notFound() }
        return .file(data: data, contentType: MIMEType.forPath("\(name).\(ext)"))
    }

    /// `marked.min.js` and `katex/` are vendored once under `SharedWebResources` (shared with the
    /// in-app prompter) rather than duplicated per-consumer, since SwiftPM requires resource
    /// basenames to be unique within a target even across subdirectories.
    private func sharedResource(name: String, ext: String) -> HTTPResponse {
        guard let data = Self.resourceData(name: name, ext: ext) else { return .notFound() }
        return .file(data: data, contentType: MIMEType.forPath("\(name).\(ext)"))
    }

    private func sharedResource(subpath: String) -> HTTPResponse {
        // subpath like "/katex/katex.min.css" or "/katex/fonts/KaTeX_Main-Regular.woff2"
        let relative = String(subpath.dropFirst())
        for root in Self.resourceRoots {
            let fileURL = root.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: fileURL) {
                return .file(data: data, contentType: MIMEType.forPath(subpath))
            }
        }
        return .notFound()
    }

    /// Candidate directories a bundled web asset can actually live in, most-likely first.
    ///
    /// This is the fix for the laptop editor reporting "Not Found" for every page it asked for.
    /// `Package.swift` declares each web asset with a **file-level** `.copy("LANServer/
    /// WebResources/editor.html")`. SwiftPM flattens a file-level `.copy` to the *root* of
    /// `Bundle.module` — the source-tree directories are not recreated inside the bundle — but
    /// the lookups here passed `subdirectory: "LANServer/WebResources"`, which exists nowhere in
    /// the built bundle. Every lookup returned `nil`, so the server answered 404 for `/`,
    /// `/editor.css` and `/editor.js` alike: the server was running and reachable the whole time,
    /// it just could not find its own HTML. (Whole-*directory* copies like `SharedWebResources/
    /// katex` do keep their directory name, hence the `katex`-bearing roots below.)
    ///
    /// Probing several roots instead of hardcoding one keeps this correct whichever way the
    /// resource declarations are written later.
    private static let resourceRoots: [URL] = {
        guard let base = Bundle.module.resourceURL else { return [] }
        return [
            base,
            base.appendingPathComponent("SharedWebResources"),
            base.appendingPathComponent("LANServer/WebResources"),
            base.appendingPathComponent("WebResources"),
        ]
    }()

    private static func resourceData(name: String, ext: String) -> Data? {
        for root in resourceRoots {
            let url = root.appendingPathComponent("\(name).\(ext)")
            if let data = try? Data(contentsOf: url) { return data }
        }
        // Last resort: let the bundle search for it wherever it ended up.
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    /// The device's LAN address. Prefers `en0` (Wi-Fi), then falls back to any other non-loopback
    /// IPv4 interface — `bridge100` when the phone is the Personal Hotspot, `en1`+ on iPad with a
    /// wired adapter. Without the fallback the Settings screen showed no URL at all on those
    /// setups, which reads as "the LAN editor doesn't work".
    private static func currentWiFiIPAddress() -> String? {
        var preferred: String?
        var fallback: String?
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        for cursor in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = cursor.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let host = String(cString: hostBuffer)
            guard !host.isEmpty, host != "0.0.0.0" else { continue }

            if name == "en0" {
                preferred = host
            } else if name.hasPrefix("en") || name.hasPrefix("bridge") {
                fallback = fallback ?? host
            }
        }
        return preferred ?? fallback
    }
}
