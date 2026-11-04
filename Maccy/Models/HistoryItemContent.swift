import CryptoKit
import Foundation
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  // External storage keeps blobs out of the row cache: reading `type` no longer loads `value`.
  @Attribute(.externalStorage) private(set) var value: Data?
  // Identifies `value` without loading it. Empty for nil values, nil only for rows
  // written before digests existed (see `Storage.migrate(then:)`).
  private(set) var digest: Data?

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil) {
    self.type = type
    self.value = value
    self.digest = Self.digest(of: value)
  }

  func update(value: Data?) {
    self.value = value
    self.digest = Self.digest(of: value)
  }

  var hasValue: Bool {
    if let digest {
      return !digest.isEmpty
    }

    // TODO: remove once all legacy rows have a digest.
    return value != nil
  }

  func hasSameValue(as other: HistoryItemContent) -> Bool {
    if let digest, let otherDigest = other.digest {
      return digest == otherDigest
    }

    // TODO: remove once all legacy rows have a digest.
    return value == other.value
  }

  /// Reads `value` through a throwaway context so the bytes are not cached on this model
  /// and are released once the caller is done with them.
  var uncachedValue: Data? {
    // Value changes always update the digest, so it tells whether the stored value is current.
    let digest = digest

    guard let container = modelContext?.container else {
      return value
    }

    let id = persistentModelID
    let context = ModelContext(container)
    var descriptor = FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.persistentModelID == id })
    descriptor.fetchLimit = 1
    // Unsaved values are only in memory.
    guard let stored = try? context.fetch(descriptor).first, stored.digest == digest else {
      return value
    }

    return stored.value
  }

  private static func digest(of value: Data?) -> Data {
    guard let value else {
      return Data()
    }

    return Data(SHA256.hash(data: value))
  }
}
