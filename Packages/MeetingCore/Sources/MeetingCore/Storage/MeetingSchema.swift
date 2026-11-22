import Foundation
import SwiftData

/// The first shipped schema of the transcript store, pinned at version 1.0.0.
///
/// Any change to `Meeting` or `Segment` (a stored property added, removed, renamed or
/// retyped, a relationship or attribute option changed) needs a new `SchemaV2` that
/// describes the new shape and a stage in `MeetingMigrationPlan`, otherwise existing
/// records on a device cannot be opened (spec: 已有记录不能丢失).
///
/// The model classes stay top-level: SwiftData does not require them to be nested in the
/// versioned schema while there is only one version. When V2 arrives, freeze the V1 shape
/// as nested copies in this enum before changing the top-level classes.
public enum SchemaV1: VersionedSchema {
    // Computed: `Schema.Version` is not `Sendable`, so a stored static would not compile in
    // Swift 6 mode.
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] { [Meeting.self, Segment.self] }
}

/// Migration plan of the transcript store. Only `SchemaV1` exists, so there are no stages.
public enum MeetingMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }

    public static var stages: [MigrationStage] { [] }
}

/// Builds the `ModelContainer` for the transcript store: the only place that names the
/// schema (`SchemaV1`) and the migration plan, used by the app and by every test.
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

    private static var schema: Schema { Schema(versionedSchema: SchemaV1.self) }

    private static func make(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: MeetingMigrationPlan.self,
                           configurations: configuration)
    }
}
