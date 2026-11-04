import AppKit.NSPasteboard
import Foundation
import Logging
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    let size = fileSize(url) + directorySize(externalDataURL)
    guard size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")
  // Where Core Data keeps values of `.externalStorage` attributes.
  private var externalDataURL: URL {
    url.deletingLastPathComponent().appending(path: ".Storage_SUPPORT/_EXTERNAL_DATA")
  }
  nonisolated private static let logger = Logger(label: "org.p0deje.Maccy")

  // History is loaded only after this, so no model in the main context refers to replaced contents.
  private(set) var migration: Task<Void, Never>?

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  /// Runs storage migrations off the main thread, then `followUp` on the main actor.
  func migrate(then followUp: @escaping @MainActor () -> Void) {
    let container = container
    migration = Task {
      await Task.detached(priority: .utility) {
        Self.externalizeLegacyContents(in: container)
      }.value
      followUp()
    }
  }

  // Rows written before `HistoryItemContent.digest` existed keep their value inline in SQLite,
  // so reading any of their attributes loads the whole blob. Re-inserting a row moves its value
  // to external storage. Batches are saved one by one, so an interrupted run resumes next launch.
  // TODO: remove once users have upgraded past the release introducing external storage.
  nonisolated private static func externalizeLegacyContents(in container: ModelContainer) {
    do {
      while try autoreleasepool(invoking: { try externalizeLegacyContentsBatch(in: container) }) > 0 {}
    } catch {
      logger.error("Failed to externalize contents: \(String(reflecting: error))")
    }
  }

  nonisolated private static func externalizeLegacyContentsBatch(in container: ModelContainer) throws -> Int {
    // A throwaway context releases each batch once it is saved.
    let context = ModelContext(container)
    var descriptor = FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.digest == nil })
    descriptor.fetchLimit = 10
    let contents = try context.fetch(descriptor)

    for content in contents {
      if let item = content.item {
        let replacement = HistoryItemContent(type: content.type, value: content.value)
        context.insert(replacement)
        replacement.item = item
      }
      context.delete(content)
    }
    try context.save()

    return contents.count
  }

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  func removeUnpersistableContents() throws -> Int {
    let contents = try context.fetch(FetchDescriptor<HistoryItemContent>())
    let unwanted = contents.filter {
      !Clipboard.shared.isPersistable(NSPasteboard.PasteboardType($0.type))
    }

    guard !unwanted.isEmpty else {
      return 0
    }

    unwanted.forEach(context.delete)
    context.processPendingChanges()
    try context.save()

    return unwanted.count
  }

  private func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }

  private func directorySize(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
      return 0
    }

    return enumerator.reduce(0) { size, file in
      size + ((file as? URL).map(fileSize) ?? 0)
    }
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }
}
