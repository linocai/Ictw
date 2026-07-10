import Foundation
import Security

enum APIError: LocalizedError, Equatable {
    case notConfigured
    case badURL
    case http(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "请先配置后端地址和 Bearer Token"
        case .badURL: "后端地址无效"
        case .http(let code, let body): body.isEmpty ? "HTTP \(code)" : body
        case .transport(let message): message
        }
    }
}

struct APIClient {
    let baseURL: String
    let token: String

    private var apiRoot: String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1"
    }

    func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: (any Encodable & Sendable)? = nil) async throws -> T {
        let data = try await rawRequest(path, method: method, body: body)
        return try JSONDecoder.lino.decode(T.self, from: data)
    }

    @discardableResult
    func rawRequest(_ path: String, method: String = "GET", body: (any Encodable & Sendable)? = nil) async throws -> Data {
        guard !baseURL.isEmpty, !token.isEmpty else { throw APIError.notConfigured }
        guard let url = URL(string: apiRoot + path) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONEncoder.lino.encode(AnyEncodable(body))
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            if !(200..<300).contains(http.statusCode) {
                throw APIError.http(http.statusCode, Self.errorMessage(from: data))
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    func streamWrite(chapterId: String, replaceDraft: Bool, onEvent: @escaping @MainActor (String, StreamPayload) -> Void) async throws {
        try await stream(path: "/chapters/\(chapterId)/write", method: "POST", body: ["replace_draft": replaceDraft], onEvent: onEvent)
    }

    func reattachWrite(chapterId: String, onEvent: @escaping @MainActor (String, StreamPayload) -> Void) async throws {
        try await stream(path: "/chapters/\(chapterId)/write/stream", method: "GET", body: nil, onEvent: onEvent)
    }

    func cancelWrite(chapterId: String) async throws -> Chapter {
        try await request("/chapters/\(chapterId)/write/cancel", method: "POST")
    }

    private func stream(
        path: String,
        method: String,
        body: (any Encodable & Sendable)?,
        onEvent: @escaping @MainActor (String, StreamPayload) -> Void
    ) async throws {
        guard !baseURL.isEmpty, !token.isEmpty else { throw APIError.notConfigured }
        guard let url = URL(string: apiRoot + path) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.lino.encode(AnyEncodable(body))
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var bodyData = Data()
            for try await byte in bytes {
                bodyData.append(byte)
            }
            throw APIError.http(http.statusCode, Self.errorMessage(from: bodyData))
        }
        var currentEvent = "message"
        for try await line in bytes.lines {
            if line.hasPrefix("event:") {
                currentEvent = line.replacingOccurrences(of: "event:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let raw = line.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
                if let payload = Self.decodeStreamPayload(raw) {
                    await onEvent(currentEvent, payload)
                }
            }
        }
    }

    private static func decodeStreamPayload(_ raw: String) -> StreamPayload? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var chapter: Chapter?
        if let chapterObject = object["chapter"] as? [String: Any],
           let chapterData = try? JSONSerialization.data(withJSONObject: chapterObject),
           let decoded = try? JSONDecoder.lino.decode(Chapter.self, from: chapterData) {
            chapter = decoded
        }
        return StreamPayload(
            text: object["text"] as? String,
            message: object["message"] as? String,
            code: object["code"] as? String,
            attempt: object["attempt"] as? Int,
            currentChars: object["current_chars"] as? Int,
            violations: object["violations"] as? [String],
            chapter: chapter
        )
    }

    private static func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] {
            if let text = detail as? String {
                return text
            }
            if let detailObject = detail as? [String: Any],
               let message = detailObject["message"] as? String {
                let nested = detailObject["details"] as? [String: Any]
                let names = nested?["names"] as? [String] ?? []
                return names.isEmpty ? message : "\(message)：\(names.joined(separator: "、"))"
            }
            if let detailData = try? JSONSerialization.data(withJSONObject: detail),
               let text = String(data: detailData, encoding: .utf8) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct AnyEncodable: Encodable, @unchecked Sendable {
    private let encodeBlock: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeBlock = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeBlock(encoder) }
}

extension JSONDecoder {
    static var lino: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

extension JSONEncoder {
    static var lino: JSONEncoder {
        let encoder = JSONEncoder()
        return encoder
    }
}

enum KeychainStore {
    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "LinoI",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "LinoI",
            kSecAttrAccount as String: key
        ]
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) != errSecSuccess {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
