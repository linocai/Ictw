import Foundation
import Security

enum APIError: LocalizedError, Equatable {
    case notConfigured
    case badURL
    case http(Int, String)
    case validation(code: String, message: String, names: [String])
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "请先配置后端地址和 Bearer Token"
        case .badURL: "后端地址无效"
        case .http(let code, let body): body.isEmpty ? "HTTP \(code)" : body
        case .validation(_, let message, let names):
            names.isEmpty ? message : "\(message)：\(names.joined(separator: "、"))"
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
                if let structured = Self.structuredError(from: data) {
                    throw APIError.validation(code: structured.code, message: structured.message, names: structured.names)
                }
                throw APIError.http(http.statusCode, Self.errorMessage(from: data))
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    /// Starts (or restarts) the background write job for a chapter. The server
    /// answers immediately with the freshly created job's status; progress is
    /// observed by polling `jobStatus(chapterId:)`.
    func startWrite(chapterId: String, replaceDraft: Bool) async throws -> WriteJobStatus {
        try await request("/chapters/\(chapterId)/write", method: "POST", body: ["replace_draft": replaceDraft])
    }

    /// Polls the latest job snapshot (write or extract) for a chapter.
    func jobStatus(chapterId: String) async throws -> WriteJobStatus {
        try await request("/chapters/\(chapterId)/job")
    }

    /// Starts the background Extractor job for a chapter's draft.
    func accept(chapterId: String) async throws -> WriteJobStatus {
        try await request("/chapters/\(chapterId)/accept", method: "POST")
    }

    func cancelWrite(chapterId: String) async throws -> Chapter {
        try await request("/chapters/\(chapterId)/write/cancel", method: "POST")
    }

    /// Extracts a `{code, message, details.names}` structured error payload
    /// (the shape used by preflight/job failures) when present.
    private static func structuredError(from data: Data) -> (code: String, message: String, names: [String])? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              let code = detail["code"] as? String,
              let message = detail["message"] as? String else { return nil }
        let details = detail["details"] as? [String: Any]
        let names = details?["names"] as? [String] ?? []
        return (code, message, names)
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
