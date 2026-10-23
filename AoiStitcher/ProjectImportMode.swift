/// Shared intake policy; independent of any workspace or project store.
nonisolated enum ProjectImportMode: Equatable, Sendable { case append, replace }
