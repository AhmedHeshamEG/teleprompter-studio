import Foundation

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Incrementally parses a raw byte buffer into a request once the header block (and, if
    /// `Content-Length` is present, the full body) has arrived. Returns `nil` if more data is
    /// needed. Framework-level HTTP/1.1 parsing since we can't depend on URLSession-side server
    /// tooling or any third-party package under xtool.
    static func parse(buffer: Data) -> (request: HTTPRequest, consumed: Int)? {
        guard let headerEndRange = buffer.range(of: Data([13, 10, 13, 10])) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let path = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key.lowercased()] = value
        }

        let bodyStart = headerEndRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let availableBodyBytes = buffer.count - bodyStart

        guard availableBodyBytes >= contentLength else { return nil }

        let body = contentLength > 0
            ? buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()

        let request = HTTPRequest(method: method, path: path, headers: headers, body: body)
        return (request, bodyStart + contentLength)
    }
}

struct HTTPResponse {
    var status: Int = 200
    var statusText: String = "OK"
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, statusText: statusText(for: status), headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    static func text(_ string: String, contentType: String = "text/plain; charset=utf-8", status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, statusText: statusText(for: status), headers: ["Content-Type": contentType], body: Data(string.utf8))
    }

    static func file(data: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, statusText: "OK", headers: ["Content-Type": contentType], body: data)
    }

    static func notFound() -> HTTPResponse {
        .text("Not Found", status: 404)
    }

    private static func statusText(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    func serialize() -> Data {
        var headerLines = "HTTP/1.1 \(status) \(statusText)\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        allHeaders["Connection"] = "close"
        allHeaders["Access-Control-Allow-Origin"] = "*"
        for (key, value) in allHeaders {
            headerLines += "\(key): \(value)\r\n"
        }
        headerLines += "\r\n"
        var data = Data(headerLines.utf8)
        data.append(body)
        return data
    }
}

enum MIMEType {
    static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "woff2": return "font/woff2"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
