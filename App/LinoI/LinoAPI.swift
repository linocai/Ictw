import Foundation
import Security

enum APIError: LocalizedError, Equatable {
    case notConfigured
    case badURL
    case http(Int, String)
    case validation(statusCode: Int, code: String, message: String, names: [String], violations: [Violation])
    case transport(String)
    /// The server deliberately omits the competing content. Clients must
    /// re-read the normal public resource before presenting a comparison.
    case writeConflict(resourceType: String, resourceId: String, submittedRevision: Int, currentRevision: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "请先配置后端地址和 Bearer Token"
        case .badURL: "后端地址无效"
        case .http(let code, let body): body.isEmpty ? "HTTP \(code)" : body
        case .validation(_, _, let message, let names, _):
            names.isEmpty ? message : "\(message)：\(names.joined(separator: "、"))"
        case .transport(let message): message
        case .writeConflict:
            "此内容已在其他设备更新。已保留本机修改，请先比较后再决定。"
        }
    }
}

struct APIClient {
    let baseURL: String
    let token: String

    var apiRoot: String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1"
    }

    func request<T: Decodable & Sendable>(
        _ path: String,
        method: String = "GET",
        body: (any Encodable & Sendable)? = nil,
        ifMatch contentRevision: Int? = nil,
        allowZeroRevision: Bool = false
    ) async throws -> T {
        let data = try await rawRequest(path, method: method, body: body, ifMatch: contentRevision, allowZeroRevision: allowZeroRevision)
        return try JSONDecoder.lino.decode(T.self, from: data)
    }

    @discardableResult
    func rawRequest(
        _ path: String,
        method: String = "GET",
        body: (any Encodable & Sendable)? = nil,
        ifMatch contentRevision: Int? = nil,
        allowZeroRevision: Bool = false
    ) async throws -> Data {
        let request = try preparedRequest(path, method: method, body: body, ifMatch: contentRevision, allowZeroRevision: allowZeroRevision)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            if !(200..<300).contains(http.statusCode) {
                if http.statusCode == 409, let conflict = Self.writeConflict(from: data) {
                    throw APIError.writeConflict(
                        resourceType: conflict.resourceType,
                        resourceId: conflict.resourceId,
                        submittedRevision: conflict.submittedRevision,
                        currentRevision: conflict.currentRevision
                    )
                }
                if let structured = Self.structuredError(from: data) {
                    throw APIError.validation(
                        statusCode: http.statusCode,
                        code: structured.code,
                        message: structured.message,
                        names: structured.names,
                        violations: structured.violations
                    )
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

    func preparedRequest(
        _ path: String,
        method: String = "GET",
        body: (any Encodable & Sendable)? = nil,
        ifMatch contentRevision: Int? = nil,
        allowZeroRevision: Bool = false
    ) throws -> URLRequest {
        guard !baseURL.isEmpty, !token.isEmpty else { throw APIError.notConfigured }
        guard let url = URL(string: apiRoot + path) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `0` means an old Backend response that predates the additive v2.1
        // field. Do not send an accidental `If-Match: \"0\"` during rolling
        // deployment; v2.1 responses always carry a positive revision.
        if let contentRevision, contentRevision > 0 || (allowZeroRevision && contentRevision == 0) {
            request.setValue("\"\(contentRevision)\"", forHTTPHeaderField: "If-Match")
        }
        if let body {
            request.httpBody = try JSONEncoder.lino.encode(AnyEncodable(body))
        }
        return request
    }

    /// Starts (or restarts) the background write job for a chapter. The server
    /// answers immediately with the freshly created job's status; progress is
    /// observed by polling `jobStatus(chapterId:)`.
    func startWrite(
        chapterId: String, replaceDraft: Bool, contentRevision: Int,
        acknowledgedContextToken: String? = nil
    ) async throws -> WriteJobStatus {
        try await request(
            "/chapters/\(chapterId)/write", method: "POST",
            body: WriteStartPayload(
                replace_draft: replaceDraft,
                acknowledged_context_token: acknowledgedContextToken
            ), ifMatch: contentRevision
        )
    }

    /// Polls the latest job snapshot (write or extract) for a chapter.
    func jobStatus(chapterId: String) async throws -> WriteJobStatus {
        try await request("/chapters/\(chapterId)/job")
    }

    /// Starts the background Extractor job for a chapter's draft.
    func accept(
        chapterId: String, contentRevision: Int, overrideChecker: Bool = false,
        allowShortDraft: Bool = false
    ) async throws -> WriteJobStatus {
        try await request(
            "/chapters/\(chapterId)/accept", method: "POST",
            body: CheckerAcceptPayload(
                override_checker: overrideChecker,
                allow_short_draft: allowShortDraft
            ), ifMatch: contentRevision
        )
    }

    func retryArchive(
        chapterId: String, contentRevision: Int, acknowledgedContextToken: String? = nil
    ) async throws -> WriteJobStatus {
        try await request(
            "/chapters/\(chapterId)/archive/retry", method: "POST",
            body: ArchiveRetryPayload(acknowledged_context_token: acknowledgedContextToken),
            ifMatch: contentRevision
        )
    }

    func rerunChecker(
        chapterId: String, contentRevision: Int, acknowledgedContextToken: String? = nil
    ) async throws -> CheckerRunResult {
        try await request(
            "/chapters/\(chapterId)/check", method: "POST",
            body: CheckerRunPayload(acknowledged_context_token: acknowledgedContextToken),
            ifMatch: contentRevision
        )
    }

    func retryCandidateChecker(
        chapterId: String, sourceJobId: String, contentRevision: Int
    ) async throws -> WriteJobStatus {
        try await request(
            "/chapters/\(chapterId)/checker/retry", method: "POST",
            body: CheckerRetryPayload(source_job_id: sourceJobId), ifMatch: contentRevision
        )
    }

    func productionReadiness(chapterId: String) async throws -> ProductionReadiness {
        try await request("/chapters/\(chapterId)/production-readiness")
    }

    func cancelWrite(chapterId: String) async throws -> Chapter {
        try await request("/chapters/\(chapterId)/write/cancel", method: "POST")
    }

    /// Read-only dry-run: mirrors exactly what a reopen's cascade would
    /// invalidate, so the client never has to guess which later chapters go
    /// stale. Safe to call while prose is still visible and unmodified.
    func rewritePreview(chapterId: String) async throws -> RewriteImpactPreview {
        try await request("/chapters/\(chapterId)/rewrite-preview")
    }

    /// Extracts a `{code, message, details.names}` structured error payload
    /// (the shape used by preflight/job failures) when present.
    static func structuredError(from data: Data) -> (code: String, message: String, names: [String], violations: [Violation])? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              let code = detail["code"] as? String,
              let message = detail["message"] as? String else { return nil }
        let details = detail["details"] as? [String: Any]
        let names = details?["names"] as? [String] ?? []
        let violations: [Violation]
        if let raw = detail["violations"],
           let violationData = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder.lino.decode([Violation].self, from: violationData) {
            violations = decoded
        } else {
            violations = []
        }
        return (code, message, names, violations)
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
        }
        // Do not surface a raw JSON/HTML response: it may contain a proxy
        // page or unsafe payload rather than the backend's public detail.
        return ""
    }

    private static func writeConflict(from data: Data) -> (resourceType: String, resourceId: String, submittedRevision: Int, currentRevision: Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              detail["code"] as? String == "write_conflict",
              let details = detail["details"] as? [String: Any],
              let resourceType = details["resource_type"] as? String,
              let resourceId = details["resource_id"] as? String,
              let submittedRevision = details["submitted_revision"] as? Int,
              let currentRevision = details["current_revision"] as? Int else { return nil }
        return (resourceType, resourceId, submittedRevision, currentRevision)
    }

    func search(query: String, bookID: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> SearchResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if let bookID { components.queryItems?.append(URLQueryItem(name: "book_id", value: bookID)) }
        return try await request("/search?\(components.percentEncodedQuery ?? "")")
    }

    func exportProject(bookID: String) async throws -> Data {
        try await rawRequest("/books/\(bookID)/project-export")
    }

    func exportData(bookID: String) async throws -> BookExportData {
        try await request("/books/\(bookID)/export-data")
    }

    func importProject(_ data: Data) async throws -> ProjectImportResult {
        var request = try preparedRequest("/books/project-import", method: "POST")
        request.setValue("application/vnd.ictw.project+zip", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? 0, Self.errorMessage(from: responseData))
            }
            return try JSONDecoder.lino.decode(ProjectImportResult.self, from: responseData)
        } catch let error as APIError { throw error }
        catch { throw APIError.transport(error.localizedDescription) }
    }
}

private struct WriteStartPayload: Encodable, Sendable {
    let replace_draft: Bool
    let acknowledged_context_token: String?
}

private struct CheckerAcceptPayload: Encodable, Sendable {
    let override_checker: Bool
    let allow_short_draft: Bool
}

private struct ArchiveRetryPayload: Encodable, Sendable {
    let acknowledged_context_token: String?
}

private struct CheckerRunPayload: Encodable, Sendable {
    let acknowledged_context_token: String?
}

private struct CheckerRetryPayload: Encodable, Sendable {
    let source_job_id: String
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
