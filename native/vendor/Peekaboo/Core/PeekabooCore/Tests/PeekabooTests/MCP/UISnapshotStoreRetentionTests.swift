import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct UISnapshotStoreRetentionTests {
    @Test
    func `Equal creation times prefer the newest insertion for implicit latest`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 3)
        let creationDate = Date(timeIntervalSinceReferenceDate: 42)
        _ = await manager.createSnapshot(id: "first", at: creationDate)
        let second = await manager.createSnapshot(id: "second", at: creationDate)

        #expect(await manager.getSnapshot(id: nil) === second)
    }

    @Test
    func `Snapshot creation evicts the oldest explicit history at the retention bound`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 3)
        for index in 0..<5 {
            _ = await manager.createSnapshot(
                id: "snapshot-\(index)",
                at: Date(timeIntervalSinceReferenceDate: Double(index)))
        }

        #expect(await manager.getSnapshot(id: "snapshot-0") == nil)
        #expect(await manager.getSnapshot(id: "snapshot-1") == nil)
        #expect(await manager.getSnapshot(id: "snapshot-2") != nil)
        #expect(await manager.getSnapshot(id: "snapshot-3") != nil)
        #expect(await manager.getSnapshot(id: "snapshot-4") != nil)
    }

    @Test
    func `Bounded eviction retains the atomically preserved snapshot`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 3)
        let preservationDate = Date(timeIntervalSinceReferenceDate: 100)
        _ = await manager.createSnapshot(id: "preserved", at: preservationDate)
        _ = await manager.invalidateImplicitLatestSnapshot(
            through: preservationDate,
            preserving: "preserved",
            preservedAt: preservationDate)

        for index in 1...3 {
            _ = await manager.createSnapshot(
                id: "new-\(index)",
                at: preservationDate.addingTimeInterval(Double(index)))
        }

        #expect(await manager.getSnapshot(id: "preserved") != nil)
        #expect(await manager.getSnapshot(id: "new-1") == nil)
        #expect(await manager.getSnapshot(id: "new-2") != nil)
        #expect(await manager.getSnapshot(id: "new-3") != nil)
    }
}
