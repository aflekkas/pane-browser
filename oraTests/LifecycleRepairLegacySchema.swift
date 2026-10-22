import Foundation
@testable import Ora
import SwiftData

/// Persisted declarations transcribed from merged PR1 commit
/// 7f7a528035a33b5cbb0abb132763ef1ca7ee4238. Transient/UI state and methods do
/// not participate in the store schema. Keep the original entity names,
/// property types, uniqueness, inverse relationships and deletion rules.
/// These are independent models, never aliases of current Ora models.
enum LifecycleRepairLegacySchema: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }
    static var models: [any PersistentModel.Type] {
        [TabContainer.self, Tab.self, Folder.self, History.self, Download.self]
    }

    @Model final class TabContainer {
        var id: UUID
        var name: String
        var emoji: String
        var createdAt: Date
        var lastAccessedAt: Date
        @Relationship(deleteRule: .cascade) var tabs: [Tab] = []
        @Relationship(deleteRule: .cascade) var folders: [Folder] = []
        @Relationship var history: [History] = []

        init(id: UUID) {
            self.id = id
            name = "PR1 space"
            emoji = "P"
            createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            lastAccessedAt = createdAt
        }
    }

    @Model final class Tab {
        var id: UUID
        var url: URL
        var urlString: String
        var savedURL: URL?
        var title: String
        var favicon: URL?
        var createdAt: Date
        var lastAccessedAt: Date?
        var type: TabType
        var order: Int
        var faviconLocalFile: URL?
        var backgroundColorHex: String = "#000000"
        @Relationship(inverse: \TabContainer.tabs) var container: TabContainer

        init(id: UUID, url: URL, container: TabContainer) {
            self.id = id
            self.url = url
            urlString = url.absoluteString
            savedURL = url
            title = "PR1 pinned tab"
            createdAt = container.createdAt
            lastAccessedAt = createdAt
            type = .pinned
            order = 7
            self.container = container
        }
    }

    @Model final class Folder {
        var id: UUID
        var name: String
        var isOpened: Bool
        @Relationship(inverse: \TabContainer.folders) var container: TabContainer

        init(container: TabContainer) {
            id = UUID()
            name = "PR1 folder"
            isOpened = true
            self.container = container
        }
    }

    @Model final class History {
        @Attribute(.unique) var id: UUID
        var url: URL
        var urlString: String
        var title: String
        var faviconURL: URL
        var faviconLocalFile: URL?
        var createdAt: Date
        var visitCount: Int
        var lastAccessedAt: Date
        @Relationship(inverse: \TabContainer.history) var container: TabContainer?

        init(url: URL, container: TabContainer) {
            id = UUID()
            self.url = url
            urlString = url.absoluteString
            title = "PR1 visit"
            faviconURL = url
            createdAt = container.createdAt
            lastAccessedAt = createdAt
            visitCount = 4
            self.container = container
        }
    }

    @Model final class Download {
        var id: UUID
        var originalURL: URL
        var originalURLString: String
        var fileName: String
        var fileSize: Int64
        var downloadedBytes: Int64
        var status: DownloadStatus
        var progress: Double
        var destinationURL: URL?
        var createdAt: Date
        var completedAt: Date?
        var error: String?

        init(id: UUID, url: URL) {
            self.id = id
            originalURL = url
            originalURLString = url.absoluteString
            fileName = "pr1-fixture.txt"
            fileSize = 4096
            downloadedBytes = 2048
            status = .failed
            progress = 0.5
            createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            error = "synthetic interrupted transfer"
        }
    }
}
