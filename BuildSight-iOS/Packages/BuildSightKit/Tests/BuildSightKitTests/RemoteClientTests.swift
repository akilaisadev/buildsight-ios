import Testing
import Foundation
@testable import BuildSightKit

/// Records every request and replies from a queue; no network involved.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var error: URLError? = nil }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let r = replies.isEmpty ? Reply(status: 200, body: "{}") : replies.removeFirst()
        if let e = r.error { throw e }
        return (Data(r.body.utf8), HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: nil)!)
    }
}

private let config = BackendConfig(baseURL: URL(string: "https://example.supabase.co")!, anonKey: "anon-key")

@Suite("REST client")
struct RemoteClientTests {
    let userID = UUID()

    private func tokens(_ transport: StubTransport) -> AuthTokenSource {
        let store = MemorySessionStore()
        store.session = AuthSession(accessToken: "tok", refreshToken: "ref", expiresAt: Date().addingTimeInterval(3600), userID: userID)
        return AuthTokenSource(store: store, auth: SupabaseAuthProvider(config: config, transport: transport))
    }

    private func backend(_ transport: StubTransport) throws -> SupabaseBackend {
        SupabaseBackend(config: config, tokens: tokens(transport), files: try EvidenceFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")), transport: transport)
    }

    private func operation(version: Int = 3) throws -> PendingOperation {
        let issue = Fixture.issue()
        let w = try RecordWrite(issue, parentID: nil, sortDate: issue.createdAt)
        return PendingOperation(recordType: .issue, recordID: issue.id, projectID: issue.projectID, payload: w.payload, baseVersion: version, createdAt: Fixture.now, parentID: nil, sortDate: issue.createdAt)
    }

    @Test("Sign-in posts the password grant and maps the token response")
    func signIn() async throws {
        let body = #"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"\#(userID.uuidString)"}}"#
        let t = StubTransport([.init(status: 200, body: body)])
        let s = try await SupabaseAuthProvider(config: config, transport: t, clock: { Fixture.now }).signIn(email: "a@b.c", password: "pw")
        #expect(s.userID == userID && s.accessToken == "a" && s.expiresAt == Fixture.now.addingTimeInterval(3600))
        let req = try #require(t.requests.first)
        #expect(req.url?.path == "/auth/v1/token" && req.url?.query == "grant_type=password")
        #expect(req.value(forHTTPHeaderField: "apikey") == "anon-key")
    }

    @Test("Auth failures map to specific errors")
    func authErrors() async {
        func attempt(_ reply: StubTransport.Reply) async -> AuthError? {
            do { _ = try await SupabaseAuthProvider(config: config, transport: StubTransport([reply])).signIn(email: "a", password: "b"); return nil }
            catch { return error as? AuthError }
        }
        #expect(await attempt(.init(status: 400, body: #"{"error_code":"invalid_credentials","msg":"x"}"#)) == .invalidCredentials)
        #expect(await attempt(.init(status: 400, body: #"{"error_code":"email_not_confirmed"}"#)) == .emailNotConfirmed)
        #expect(await attempt(.init(status: 400, body: #"{"error_code":"user_banned"}"#)) == .accountDisabled)
        #expect(await attempt(.init(status: 0, body: "", error: URLError(.notConnectedToInternet))) == .network)
    }

    @Test("A rejected refresh token means the session is expired, not that the password is wrong")
    func refreshRejected() async {
        let t = StubTransport([.init(status: 400, body: #"{"error_code":"refresh_token_not_found"}"#)])
        let session = AuthSession(accessToken: "a", refreshToken: "r", expiresAt: Fixture.now, userID: userID)
        await #expect(throws: AuthError.sessionExpired) { _ = try await SupabaseAuthProvider(config: config, transport: t).refresh(session) }
    }

    @Test("Password reset calls the recover endpoint")
    func reset() async throws {
        let t = StubTransport([.init(status: 200, body: "{}")])
        try await SupabaseAuthProvider(config: config, transport: t).sendPasswordReset(email: "a@b.c")
        #expect(t.requests.first?.url?.path == "/auth/v1/recover")
    }

    @Test("Upsert calls the RPC with the idempotency key and base version and returns the new server version")
    func upsertSuccess() async throws {
        let t = StubTransport([.init(status: 200, body: "4")])
        let op = try operation(version: 3)
        let ack = try await backend(t).upsert(op, objectPath: nil)
        #expect(ack.serverVersion == 4)
        let req = try #require(t.requests.first)
        #expect(req.url?.path == "/rest/v1/rpc/upsert_record")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(req.httpBody.flatMap { try? JSONValue.parse($0).objectValue })
        #expect(body["p_operation"] == .string(op.id.uuidString))
        #expect(body["p_base_version"] == .number(3))
        #expect(body["p_id"] == .string(op.recordID.uuidString))
    }

    @Test("Server error classes map to the engine's retry semantics")
    func errorMapping() async throws {
        func attempt(_ reply: StubTransport.Reply) async -> RemoteError? {
            do { _ = try await backend(StubTransport([reply])).upsert(try operation(), objectPath: nil); return nil }
            catch { return error as? RemoteError }
        }
        #expect(await attempt(.init(status: 401, body: "")) == .unauthorized)
        #expect(await attempt(.init(status: 503, body: "")) == .transient("Server error 503"))
        #expect(await attempt(.init(status: 0, body: "", error: URLError(.notConnectedToInternet))) == .offline)
        #expect(await attempt(.init(status: 403, body: "role_not_permitted")) == .rejected("Your role isn't allowed to make this change."))
        #expect(await attempt(.init(status: 400, body: "not_a_member")) == .rejected("You aren't a member of this project."))
    }

    @Test("A version conflict fetches the server copy and reports it for merging")
    func conflict() async throws {
        let rows = #"[{"payload":{"title":"Server title"},"server_version":7}]"#
        let t = StubTransport([.init(status: 409, body: #"{"message":"version_conflict"}"#), .init(status: 200, body: rows)])
        do { _ = try await backend(t).upsert(try operation(), objectPath: nil); Testing.Issue.record("expected conflict") }
        catch RemoteError.conflict(let record, let version) {
            #expect(version == 7)
            #expect(try JSONValue.parse(record).objectValue?["serverVersion"] == .number(7))
        }
    }

    @Test("Evidence uploads go to a path derived from project and photo ids and overwrite on retry")
    func upload() async throws {
        let t = StubTransport([.init(status: 200, body: "{}")])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        let files = try EvidenceFileStore(directory: dir)
        let saved = try files.save(jpeg: makeJPEG(), photoID: UUID())
        let b = SupabaseBackend(config: config, tokens: tokens(t), files: files, transport: t)
        let photoID = UUID()
        let path = try await b.uploadEvidence(projectID: Fixture.projectA, photoID: photoID, localFilename: saved.filename)
        #expect(path == "\(Fixture.projectA.uuidString)/\(photoID.uuidString).jpg")
        #expect(t.requests.first?.value(forHTTPHeaderField: "x-upsert") == "true")
        #expect((t.requests.first?.httpBody?.count ?? 0) > 100)
    }

    @Test("Pulling decodes rows, patches in the server version and drops malformed rows")
    func pull() async throws {
        let id = UUID()
        let rows = """
        [{"id":"\(id.uuidString)","type":"issue","project_id":"\(Fixture.projectA.uuidString)","parent_id":null,"sort_date":"2026-09-25T06:30:00.000Z","updated_at":"2026-09-25T06:31:00.000Z","server_version":5,"payload":{"title":"T"}},
         {"id":"not-a-uuid","type":"issue"}]
        """
        let t = StubTransport([.init(status: 200, body: rows)])
        let got = try await backend(t).fetchChanges(projectID: Fixture.projectA, since: Fixture.now)
        #expect(got.count == 1 && got[0].id == id && got[0].serverVersion == 5)
        #expect(try JSONValue.parse(got[0].payload).objectValue?["serverVersion"] == .number(5))
        #expect(t.requests.first?.url?.query?.contains("updated_at=gt.") == true)
        #expect(t.requests.first?.url?.query?.contains("project_id=eq.\(Fixture.projectA.uuidString)") == true)
    }

    @Test("An expired token is refreshed before the call; a dead refresh token stops the sync with unauthorized")
    func tokenRefresh() async throws {
        let store = MemorySessionStore()
        store.session = AuthSession(accessToken: "old", refreshToken: "r", expiresAt: Date().addingTimeInterval(-60), userID: userID)
        let fresh = #"{"access_token":"new","refresh_token":"r2","expires_in":3600,"user":{"id":"\#(userID.uuidString)"}}"#
        let ok = AuthTokenSource(store: store, auth: SupabaseAuthProvider(config: config, transport: StubTransport([.init(status: 200, body: fresh)])))
        #expect(try await ok.validToken() == "new")
        #expect(store.session?.accessToken == "new")

        store.session = AuthSession(accessToken: "old", refreshToken: "r", expiresAt: Date().addingTimeInterval(-60), userID: userID)
        let dead = AuthTokenSource(store: store, auth: SupabaseAuthProvider(config: config, transport: StubTransport([.init(status: 400, body: #"{"error_code":"refresh_token_not_found"}"#)])))
        await #expect(throws: RemoteError.unauthorized) { _ = try await dead.validToken() }
    }
}
