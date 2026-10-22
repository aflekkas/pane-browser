import Foundation
import SwiftData

extension ModelConfiguration {
    /// True when running inside an XCTest host. Tests must never touch the
    /// user's on-disk store: the test host has no app container of its own,
    /// and creating one would both fail under sandbox and pollute real data.
    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static var oraStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Ora/OraData.sqlite")
    }

    /// Creates the store's parent directory. SwiftData does not reliably
    /// create intermediate directories for a custom store URL, so a fresh
    /// install (or a relocated container) previously failed with
    /// NSCocoaErrorDomain 512 before any data could be written.
    static func prepareStoreDirectory(for storeURL: URL) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Shared model configuration for the main Ora database
    static func oraDatabase(isPrivate: Bool = false) -> ModelConfiguration {
        if isPrivate || isRunningUnitTests {
            return ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            return ModelConfiguration(
                "OraData",
                schema: Schema([TabContainer.self, History.self, Download.self]),
                url: oraStoreURL
            )
        }
    }

    /// On-disk configuration for an explicit store URL (used by the
    /// persistent-store smoke test; production goes through `oraDatabase`).
    static func oraDatabase(at storeURL: URL) -> ModelConfiguration {
        ModelConfiguration(
            "OraData",
            schema: Schema([TabContainer.self, History.self, Download.self]),
            url: storeURL
        )
    }

    /// Creates a ModelContainer using the standard Ora database configuration
    static func createOraContainer(isPrivate: Bool = false) throws -> ModelContainer {
        if !isPrivate, !isRunningUnitTests {
            try prepareStoreDirectory(for: oraStoreURL)
        }
        return try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: oraDatabase(isPrivate: isPrivate)
        )
    }

    /// Creates a persistent container at an explicit URL, preparing its
    /// directory first. Used by the smoke test so persistent behaviour is
    /// validated without touching the production store location.
    static func createOraContainer(at storeURL: URL) throws -> ModelContainer {
        try prepareStoreDirectory(for: storeURL)
        return try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: oraDatabase(at: storeURL)
        )
    }
}
