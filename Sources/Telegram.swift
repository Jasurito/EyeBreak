import Foundation
import Security

/// Minimal Telegram Bot API client. The token is part of the URL, so requests use an
/// ephemeral session that never writes them to the HTTP cache.
enum Telegram {
    enum Failure: LocalizedError {
        case noToken
        case noMessages
        case api(String)

        var errorDescription: String? {
            switch self {
            case .noToken: return "No bot token saved."
            case .noMessages: return "No messages found. Send /start to your bot in Telegram, then try again."
            case .api(let description): return "Telegram said: \(description)"
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    static func isValidToken(_ token: String) -> Bool {
        token.range(of: #"^\d+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    /// A number, or an @username for a channel.
    static func isValidChatID(_ chatID: String) -> Bool {
        chatID.range(of: #"^(-?\d+|@[A-Za-z0-9_]+)$"#, options: .regularExpression) != nil
    }

    static func send(_ text: String, token: String, chatID: String) async throws {
        _ = try await call("sendMessage", token: token, body: ["chat_id": chatID, "text": text], as: Ignored.self)
    }

    /// The chat that most recently messaged the bot, which is how you find your chat ID.
    static func latestChat(token: String) async throws -> (id: String, name: String) {
        let updates = try await call("getUpdates", token: token, body: [:], as: [Update].self)
        guard let chat = updates.compactMap(\.message?.chat).last else { throw Failure.noMessages }
        return (String(chat.id), chat.title ?? chat.firstName ?? chat.username ?? "Unknown")
    }

    private static func call<Result: Decodable>(_ method: String, token: String, body: [String: String],
                                                as type: Result.Type) async throws -> Result {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw Failure.api("Invalid bot token")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response<Result>.self, from: data)
        guard response.ok, let result = response.result else {
            throw Failure.api(response.description ?? "Unknown error")
        }
        return result
    }

    private struct Response<Result: Decodable>: Decodable {
        let ok: Bool
        let description: String?
        let result: Result?
    }

    private struct Ignored: Decodable {}

    private struct Update: Decodable {
        struct Message: Decodable {
            struct Chat: Decodable {
                let id: Int64
                let title: String?
                let firstName: String?
                let username: String?
            }
            let chat: Chat
        }
        let message: Message?
    }
}

/// The bot token lives in the login Keychain. Reading it can show a macOS password prompt,
/// so call `read()` off the main thread.
enum TelegramToken {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jasurito.EyeBreak",
        kSecAttrAccount as String: "telegram-bot-token",
    ]

    /// Only looks at the item's attributes, so this never prompts.
    static var isSaved: Bool {
        var query = item
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) -> Bool {
        delete()
        var attributes = item
        attributes[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(item as CFDictionary)
    }
}
