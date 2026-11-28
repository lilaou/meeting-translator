import Foundation
import SwiftData

/// The first shipped schema of the transcript store, pinned at version 1.0.0.
///
/// Records written with this schema are on devices, so it must stay as it is (spec:
/// 已有记录不能丢失).
///
/// `Meeting` and `Segment` stay top-level and are shared with `SchemaV2`, which did not
/// change them. Before a later version changes either class (a stored property added,
/// removed, renamed or retyped, a relationship or attribute option changed), freeze the
/// shape as nested copies in each earlier version that lists it.
public enum SchemaV1: VersionedSchema {
    // Computed: `Schema.Version` is not `Sendable`, so a stored static would not compile in
    // Swift 6 mode.
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] { [Meeting.self, Segment.self] }
}

/// Version 2.0.0: `SchemaV1` plus saved face-to-face conversations.
///
/// Any change to one of its models needs a new schema version and a stage in
/// `MeetingMigrationPlan`, otherwise existing records on a device cannot be opened.
public enum SchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        SchemaV1.models + [ConversationRecord.self, ConversationTurnRecord.self]
    }
}

/// Migration plan of the transcript store. 1.0.0 to 2.0.0 only adds entities, so the stage
/// is lightweight.
public enum MeetingMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }

    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}

/// Builds the `ModelContainer` for the transcript store: the only place that names the
/// schema (`SchemaV2`) and the migration plan, used by the app and by every test.
///
/// `@MainActor`: containers are created one at a time. Two containers for this schema
/// created at once on different threads crashed inside Core Data (store setup races on the
/// shared model, seen on macOS 15). The app builds its container on the main actor anyway,
/// and `TranscriptStore` uses its `mainContext`.
@MainActor public enum MeetingStorage {
    /// The on-disk container the app uses (`url` is the SQLite store file; it is created
    /// if missing and migrated with `MeetingMigrationPlan` if it is older).
    ///
    /// The app builds it ONCE, on the main actor, and passes that same instance to both
    /// SwiftUI's `.modelContainer(_:)` and `TranscriptStore(container:)`, so `@Query` and the
    /// store share one `mainContext`. `url` should point into Application Support, and its
    /// parent directory must already exist.
    public static func makeContainer(at url: URL) throws -> ModelContainer {
        try make(ModelConfiguration(schema: schema, url: url))
    }

    /// A container that lives in memory only (tests, previews). Each call is a new store.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        try make(ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private static var schema: Schema { Schema(versionedSchema: SchemaV2.self) }

    private static func make(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: MeetingMigrationPlan.self,
                           configurations: configuration)
    }
}
