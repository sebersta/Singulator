import Foundation
import Security

enum ParcelKeychain {
    private static let service = "com.sebersta.ParcelSingulator"
    private static let apiKeyAccount = "Parcel API Key"
    private static let automationAccount = "Parcel Automation Enabled"
    private static let triggerWordsAccount = "Shipment Trigger Words"

    static var triggerWords: String {
        load(account: triggerWordsAccount) ?? "track,kollinr"
    }

    static func saveTriggerWords(_ value: String) throws {
        try save(value, account: triggerWordsAccount)
    }

    static func load() -> String? {
        load(account: apiKeyAccount)
    }

    static func save(_ value: String) throws {
        try save(value, account: apiKeyAccount)
    }

    static var isAutomationEnabled: Bool {
        load(account: automationAccount).map { $0 == "true" } ?? (load() != nil)
    }

    static func setAutomationEnabled(_ isEnabled: Bool) throws {
        try save(String(isEnabled), account: automationAccount)
    }

    private static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            var item = baseQuery(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String,
           !group.isEmpty, !group.contains("$(") {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"]
            )
        }
    }
}
