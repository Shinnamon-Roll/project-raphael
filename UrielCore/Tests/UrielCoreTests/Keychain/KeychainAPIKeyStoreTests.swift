import Foundation
import Testing
import UrielCore

// Writes to the login keychain, but only under a unique test service, never the owner's key.
@Test func keyRoundTripsThroughTheKeychain() async throws {
  let store = KeychainAPIKeyStore(service: "com.shinnamon.uriel.tests.\(UUID().uuidString)")
  #expect(store.service != KeychainAPIKeyStore.defaultService)
  defer { try? await store.delete() }  // Runs even when an expectation or a call fails.

  await #expect(throws: APIKeyError.missing) { try await store.apiKey() }
  await #expect(throws: APIKeyError.missing) { try await store.save(" \n") }

  try await store.save("test-key-one\n")
  #expect(try await store.apiKey() == "test-key-one")

  try await store.save("test-key-two")
  #expect(try await store.apiKey() == "test-key-two")

  try await store.delete()
  await #expect(throws: APIKeyError.missing) { try await store.apiKey() }
  try await store.delete()  // Deleting again is not an error.
}
