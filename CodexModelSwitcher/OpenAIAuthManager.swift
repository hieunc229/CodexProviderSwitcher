import Foundation

struct OpenAIAuthManager {
    func loginAccount(suggestedName: String) async throws -> OpenAIAccount {
        let loginID = UUID().uuidString
        let loginHome = AppPaths.loginDirectory.appendingPathComponent(loginID, isDirectory: true)
        try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: loginHome)
        }

        try await runCodexLogin(codeHome: loginHome)

        let authURL = loginHome.appendingPathComponent("auth.json")
        let authJSON = try String(contentsOf: authURL, encoding: .utf8)
        let accountID = extractAccountID(from: authJSON)
        let email = extractEmail(from: authJSON)
        let suffix = accountID.map { String($0.suffix(6)) }
        let name = email ?? suffix.map { "\(suggestedName) \($0)" } ?? suggestedName

        return OpenAIAccount(
            id: UUID().uuidString,
            name: name,
            authJSON: authJSON,
            accountID: accountID,
            email: email,
            credentialStatus: .valid,
            credentialMessage: nil,
            createdAt: Date()
        )
    }

    func validateAccount(_ account: OpenAIAccount) async -> OpenAICredentialCheckResult {
        if accessTokenIsUsable(account.authJSON) {
            return OpenAICredentialCheckResult(status: .valid, message: nil, authJSON: nil)
        }

        do {
            let refreshedAuthJSON = try await refreshAuthJSON(account.authJSON)
            return OpenAICredentialCheckResult(status: .valid, message: nil, authJSON: refreshedAuthJSON)
        } catch {
            return OpenAICredentialCheckResult(status: .invalid, message: "Not valid. Please re-login.")
        }
    }

    private func accessTokenIsUsable(_ authJSON: String) -> Bool {
        guard let data = authJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let expirationDate = jwtExpirationDate(accessToken) else {
            return false
        }

        return expirationDate.timeIntervalSinceNow > 300
    }

    private func refreshAuthJSON(_ authJSON: String) async throws -> String {
        guard let data = authJSON.data(using: .utf8),
              var auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = auth["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String,
              !refreshToken.isEmpty else {
            throw AppError.openAIAccountLoginFailed
        }

        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OpenAIRefreshRequest(refreshToken: refreshToken))

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.openAIAccountLoginFailed
        }

        let refreshResponse = try JSONDecoder().decode(OpenAIRefreshResponse.self, from: responseData)
        if let idToken = refreshResponse.idToken {
            tokens["id_token"] = idToken
        }
        if let accessToken = refreshResponse.accessToken {
            tokens["access_token"] = accessToken
        }
        if let refreshToken = refreshResponse.refreshToken {
            tokens["refresh_token"] = refreshToken
        }

        auth["tokens"] = tokens
        auth["last_refresh"] = iso8601Now()

        let updatedData = try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])
        return String(data: updatedData, encoding: .utf8) ?? authJSON
    }

    private func runCodexLogin(codeHome: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = codexExecutableURL()
            process.arguments = codexArguments()
            process.environment = loginEnvironment(codeHome: codeHome)
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppError.openAIAccountLoginFailed)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func codexExecutableURL() -> URL {
        let bundled = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private func codexArguments() -> [String] {
        let loginArguments = [
            "login",
            "-c",
            #"cli_auth_credentials_store="file""#
        ]

        if codexExecutableURL().path == "/usr/bin/env" {
            return ["codex"] + loginArguments
        }
        return loginArguments
    }

    private func loginEnvironment(codeHome: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codeHome.path
        return environment
    }

    func extractAccountID(from authJSON: String) -> String? {
        guard let data = authJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any] else {
            return nil
        }
        return tokens["account_id"] as? String
    }

    func extractEmail(from authJSON: String) -> String? {
        guard let data = authJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else {
            return nil
        }

        let parts = idToken.split(separator: ".")
        guard parts.count > 1,
              let payloadData = base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        return payload["email"] as? String
    }

    private func jwtExpirationDate(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count > 1,
              let payloadData = base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = payload["exp"] as? TimeInterval else {
            return nil
        }

        return Date(timeIntervalSince1970: exp)
    }

    private func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private struct OpenAIRefreshRequest: Encodable {
    let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    let grantType = "refresh_token"
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
    }
}

private struct OpenAIRefreshResponse: Decodable {
    let accessToken: String?
    let idToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
    }
}

struct OpenAICredentialCheckResult {
    var status: OpenAIAccountCredentialStatus
    var message: String?
    var authJSON: String?
}
