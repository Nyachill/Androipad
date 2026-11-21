import Foundation
import Security

/// 接続先とパスワード。パスワードはキーチェーンに保存する
@MainActor
final class ViewerSettings: ObservableObject {
    static let defaultURL = "https://android.amgm.jp/"
    private static let urlKey = "serverURL"
    private static let keychainService = "jp.amgm.androidviewer"
    private static let keychainAccount = "android"

    @Published var serverURL: String
    @Published var password: String
    @Published var showSetup = false

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL
        password = Self.loadPassword() ?? ""
    }

    var isConfigured: Bool {
        URL(string: serverURL)?.host != nil && !password.isEmpty
    }

    var url: URL? { URL(string: serverURL) }

    func save() {
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("http") { trimmed = "https://" + trimmed }
        if !trimmed.hasSuffix("/") { trimmed += "/" }
        serverURL = trimmed
        password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: Self.urlKey)
        Self.storePassword(password)
        showSetup = false
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func loadPassword() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func storePassword(_ password: String) {
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}
