import Foundation
import Security

/// Why the API key could not be read or kept. It never holds the key itself.
public enum APIKeyError: Error, Sendable, Hashable {
  /// No key is stored, or the stored one is empty. The turn loop says so out loud.
  case missing
  /// The Keychain refused, for example when the owner denied the access prompt.
  case keychain(status: OSStatus)
}

/// The Claude API key, kept as a generic password in the owner's login keychain (ADR 0005).
///
/// It uses the file-based keychain, not the data protection keychain: that one needs a
/// keychain-access-groups entitlement, which `swift test` and the command-line spikes do not
/// have. So the signed app, the unsigned test runner, the spikes and `security` all reach the
/// same item, and its access list prompts the owner the first time another program reads it.
public struct KeychainAPIKeyStore: APIKeyProvider {
  /// Uriel's bundle ID, fixed as a constant because the spikes and tests have no bundle.
  public static let defaultService = "com.shinnamon.uriel"
  public static let defaultAccount = "anthropic-api-key"

  public let service: String
  public let account: String

  /// Tests pass their own `service`, so they never touch the owner's key.
  public init(service: String = defaultService, account: String = defaultAccount) {
    self.service = service
    self.account = account
  }

  private var query: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
  }

  // The SecItem calls block, and may wait on a keychain prompt, so they run off the caller's
  // actor (`@concurrent`).

  /// Reads the key. Throws ``APIKeyError/missing`` when none is stored.
  @concurrent public func apiKey() async throws -> String {
    var query = query
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { throw APIKeyError.missing }
    guard status == errSecSuccess else { throw APIKeyError.keychain(status: status) }
    let data = result as? Data ?? Data()
    // A stored but undecodable key is corrupt, not missing.
    guard let key = String(data: data, encoding: .utf8) else {
      throw APIKeyError.keychain(status: errSecDecode)
    }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw APIKeyError.missing }
    return trimmed
  }

  /// Stores `key`, replacing any stored one. Throws ``APIKeyError/missing`` when `key` is blank.
  @concurrent public func save(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw APIKeyError.missing }
    let data = Data(trimmed.utf8)
    var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData] = data
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw APIKeyError.keychain(status: status) }
  }

  /// Deletes the stored key. Deleting when none is stored succeeds.
  @concurrent public func delete() async throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw APIKeyError.keychain(status: status)
    }
  }
}
