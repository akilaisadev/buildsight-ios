import Foundation

/// Backend location and public (anon) key. The anon key is designed to be
/// shipped in clients; real access control is row-level security on the server.
/// Never put a service-role key in the app.
public struct BackendConfig: Sendable, Equatable {
    public var baseURL: URL
    public var anonKey: String
    public var evidenceBucket = "evidence"

    public init(baseURL: URL, anonKey: String) {
        self.baseURL = baseURL
        self.anonKey = anonKey
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum HTTP {
    static func request(_ config: BackendConfig, path: String, query: [URLQueryItem] = [], method: String = "GET", token: String? = nil, body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) ?? URLComponents()
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url ?? config.baseURL)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token ?? config.anonKey)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return request
    }

    static func isConnectivity(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff].contains(e.code)
    }
}

// MARK: - Auth

public struct SupabaseAuthProvider: AuthProvider {
    private let config: BackendConfig
    private let transport: HTTPTransport
    private let clock: @Sendable () -> Date

    public init(config: BackendConfig, transport: HTTPTransport = URLSession.shared, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.transport = transport
        self.clock = clock
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { let id: UUID }
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
    }
    private struct ErrorBody: Decodable { let error_code: String?; let msg: String?; let error_description: String?; let message: String? }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.send(request) }
        catch { throw HTTP.isConnectivity(error) ? AuthError.network : AuthError.other(error.localizedDescription) }
    }

    private func mapFailure(_ data: Data, status: Int, refreshing: Bool) -> AuthError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let code = body?.error_code ?? ""
        if code == "email_not_confirmed" { return .emailNotConfirmed }
        if code == "user_banned" { return .accountDisabled }
        if status == 400 || status == 401 || status == 403 { return refreshing ? .sessionExpired : .invalidCredentials }
        return .other(body?.msg ?? body?.message ?? "Sign-in failed (\(status)).")
    }

    private func tokenRequest(grant: String, body: [String: String]) async throws -> AuthSession {
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = HTTP.request(config, path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: grant)], method: "POST", body: data)
        let (payload, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else { throw mapFailure(payload, status: response.statusCode, refreshing: grant == "refresh_token") }
        let t = try JSONDecoder().decode(TokenResponse.self, from: payload)
        return AuthSession(accessToken: t.access_token, refreshToken: t.refresh_token, expiresAt: clock().addingTimeInterval(t.expires_in), userID: t.user.id)
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        try await tokenRequest(grant: "password", body: ["email": email, "password": password])
    }

    public func refresh(_ session: AuthSession) async throws -> AuthSession {
        try await tokenRequest(grant: "refresh_token", body: ["refresh_token": session.refreshToken])
    }

    public func signOut(_ session: AuthSession) async throws {
        let request = HTTP.request(config, path: "auth/v1/logout", method: "POST", token: session.accessToken)
        _ = try await perform(request)
    }

    public func sendPasswordReset(email: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["email": email])
        let (payload, response) = try await perform(HTTP.request(config, path: "auth/v1/recover", method: "POST", body: data))
        // The server answers 200 whether or not the address exists, so the UI
        // cannot be used to discover which emails have accounts.
        guard (200..<300).contains(response.statusCode) else { throw mapFailure(payload, status: response.statusCode, refreshing: false) }
    }

    public func fetchProfile(for session: AuthSession) async throws -> UserProfile {
        struct ProfileRow: Decodable {
            struct Org: Decodable { let name: String }
            let display_name: String
            let organisations: Org?
        }
        struct MembershipRow: Decodable { let project_id: UUID; let role: Role }
        struct UserRow: Decodable { let email: String }

        func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
            let (data, response) = try await perform(HTTP.request(config, path: path, query: query, token: session.accessToken))
            if response.statusCode == 401 { throw AuthError.sessionExpired }
            guard (200..<300).contains(response.statusCode) else { throw AuthError.other("Profile request failed (\(response.statusCode)).") }
            return data
        }
        let id = session.userID.uuidString
        let profiles = try JSONDecoder().decode([ProfileRow].self, from: try await get("rest/v1/profiles", [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "display_name,organisations(name)")]))
        let members = try JSONDecoder().decode([MembershipRow].self, from: try await get("rest/v1/memberships", [URLQueryItem(name: "user_id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "project_id,role")]))
        let user = try JSONDecoder().decode(UserRow.self, from: try await get("auth/v1/user", []))
        guard let profile = profiles.first else { throw AuthError.accountDisabled }
        return UserProfile(id: session.userID, displayName: profile.display_name, email: user.email, organisationName: profile.organisations?.name ?? "", memberships: members.map { ProjectMembership(projectID: $0.project_id, role: $0.role) })
    }
}

/// Hands out a valid access token, refreshing it when it is about to expire.
public actor AuthTokenSource {
    private let store: SecureSessionStore
    private let auth: AuthProvider
    private let clock: @Sendable () -> Date

    public init(store: SecureSessionStore, auth: AuthProvider, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.auth = auth
        self.clock = clock
    }

    public func validToken() async throws -> String {
        guard var session = store.load() else { throw RemoteError.unauthorized }
        if session.isExpired(at: clock()) {
            do { session = try await auth.refresh(session); try store.save(session) }
            catch AuthError.network { throw RemoteError.offline }
            catch { throw RemoteError.unauthorized }
        }
        return session.accessToken
    }
}

// MARK: - Records

public struct SupabaseBackend: RemoteBackend, RemotePuller {
    private let config: BackendConfig
    private let transport: HTTPTransport
    private let tokens: AuthTokenSource
    private let files: EvidenceFileStoring

    public init(config: BackendConfig, tokens: AuthTokenSource, files: EvidenceFileStoring, transport: HTTPTransport = URLSession.shared) {
        self.config = config
        self.tokens = tokens
        self.files = files
        self.transport = transport
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.send(request) }
        catch { throw HTTP.isConnectivity(error) ? RemoteError.offline : RemoteError.transient(error.localizedDescription) }
    }

    private func classify(_ data: Data, _ response: HTTPURLResponse) -> RemoteError {
        let text = String(decoding: data, as: UTF8.self)
        switch response.statusCode {
        case 401: return .unauthorized
        case 409: return .transient("conflict")        // replaced by explicit P0409 handling in upsert
        case 408, 429, 500...599: return .transient("Server error \(response.statusCode)")
        default: return .rejected(text.isEmpty ? "Rejected (\(response.statusCode))" : text)
        }
    }

    public func upsert(_ operation: PendingOperation, objectPath: String?) async throws -> RemoteAck {
        let token = try await tokens.validToken()
        let payload = try JSONValue.parse(operation.payload)
                let body: [String: JSONValue] = [
            "p_id": .string(operation.recordID.uuidString), "p_type": .string(operation.recordType.rawValue),
            "p_project": .string(operation.projectID.uuidString), "p_parent": operation.parentID.map { .string($0.uuidString) } ?? .null,
            "p_sort_date": .string(Self.iso(operation.sortDate ?? operation.createdAt)), "p_payload": payload,
            "p_object_path": objectPath.map(JSONValue.string) ?? .null,
            "p_base_version": .number(Double(operation.baseVersion)), "p_operation": .string(operation.id.uuidString),
        ]
        let request = HTTP.request(config, path: "rest/v1/rpc/upsert_record", method: "POST", token: token, body: try JSONValue.object(body).data())
        let (data, response) = try await perform(request)

        if (200..<300).contains(response.statusCode) {
            guard let version = try? JSONDecoder().decode(Int.self, from: data) else { throw RemoteError.transient("Unexpected response") }
            return RemoteAck(serverVersion: version)
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("version_conflict") { throw try await fetchConflict(operation, token: token) }
        if text.contains("role_not_permitted") { throw RemoteError.rejected("Your role isn't allowed to make this change.") }
        if text.contains("not_a_member") { throw RemoteError.rejected("You aren't a member of this project.") }
        throw classify(data, response)
    }

    private func fetchConflict(_ operation: PendingOperation, token: String) async throws -> RemoteError {
        let query = [URLQueryItem(name: "id", value: "eq.\(operation.recordID.uuidString)"), URLQueryItem(name: "select", value: "payload,server_version")]
        let (data, response) = try await perform(HTTP.request(config, path: "rest/v1/records", query: query, token: token))
        guard (200..<300).contains(response.statusCode) else { return classify(data, response) }
        guard let row = (try? JSONValue.parse(data))?.arrayValue?.first?.objectValue,
              case .number(let v)? = row["server_version"], var payload = row["payload"]?.objectValue else { return .transient("Conflict record unavailable") }
        payload["serverVersion"] = .number(v)
        return .conflict(serverRecord: try JSONValue.object(payload).data(), serverVersion: Int(v))
    }

    public func uploadEvidence(projectID: UUID, photoID: UUID, localFilename: String) async throws -> String {
        let token = try await tokens.validToken()
        let path = "\(projectID.uuidString)/\(photoID.uuidString).jpg"      // deterministic: re-upload overwrites
        let fileURL = files.url(forFilename: localFilename)
        guard let data = try? Data(contentsOf: fileURL) else { throw RemoteError.rejected("The local photo file is missing.") }
        var request = HTTP.request(config, path: "storage/v1/object/\(config.evidenceBucket)/\(path)", method: "POST", token: token, body: nil, headers: ["x-upsert": "true", "Content-Type": "image/jpeg"])
        request.httpBody = data
        let (body, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else { throw classify(body, response) }
        return path
    }

    public func fetchChanges(projectID: UUID, since: Date?) async throws -> [RemoteRecord] {
        let token = try await tokens.validToken()
        var query = [URLQueryItem(name: "project_id", value: "eq.\(projectID.uuidString)"),
                     URLQueryItem(name: "select", value: "id,type,project_id,parent_id,sort_date,payload,server_version,updated_at"),
                     URLQueryItem(name: "order", value: "updated_at.asc"), URLQueryItem(name: "limit", value: "1000")]
        if let since { query.append(URLQueryItem(name: "updated_at", value: "gt.\(Self.iso(since))")) }
        let (data, response) = try await perform(HTTP.request(config, path: "rest/v1/records", query: query, token: token))
        guard (200..<300).contains(response.statusCode) else { throw classify(data, response) }
        guard let rows = try JSONValue.parse(data).arrayValue else { return [] }

        return rows.compactMap { row -> RemoteRecord? in
            guard let o = row.objectValue, case .string(let id)? = o["id"], let uuid = UUID(uuidString: id),
                  case .string(let type)? = o["type"], let recordType = RecordType(rawValue: type),
                  case .string(let project)? = o["project_id"], let pid = UUID(uuidString: project),
                  case .number(let version)? = o["server_version"], var payload = o["payload"]?.objectValue,
                  case .string(let sort)? = o["sort_date"], case .string(let updated)? = o["updated_at"],
                  let sortDate = Self.parse(sort), let updatedAt = Self.parse(updated) else { return nil }
            payload["serverVersion"] = .number(version)
            guard let bytes = try? JSONValue.object(payload).data() else { return nil }
            var parent: UUID?
            if case .string(let p)? = o["parent_id"] { parent = UUID(uuidString: p) }
            return RemoteRecord(type: recordType, id: uuid, projectID: pid, parentID: parent, sortDate: sortDate, updatedAt: updatedAt, serverVersion: Int(version), payload: bytes)
        }
    }

    // MARK: helpers

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func iso(_ d: Date) -> String { formatter.string(from: d) }
    static func parse(_ s: String) -> Date? { formatter.date(from: s) ?? plain.date(from: s) }

}

extension JSONValue {
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}
