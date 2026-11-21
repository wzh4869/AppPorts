import Foundation

struct DataTaskRecoveryScope: Sendable {
    let jobID: UUID
    let resources: MigrationResources
    let startedAt: Date?
    let elapsed: TimeInterval

    func operationIDs(transfers: [DataTransferRecord], materials: [DataTransferMaterial]) -> Set<UUID> {
        let records = transfers + materials.compactMap(\.recoveryRecord)
        var selected = resources.dataOperationIDs ?? []
        selected.formUnion(records.filter { $0.migrationTaskID == jobID }.map(\.id))
        guard resources.dataOperationIDs == nil, let startedAt else { return selected }

        // Old history has no task ID. An exact subject and a unique journal
        // created during this attempt are both required, even for archived material.
        var byPath: [String: Set<UUID>] = [:]
        for record in transfers { byPath[record.originalPath, default: []].insert(record.id) }
        for material in materials { byPath[material.originalPath, default: []].insert(material.id) }
        let end = startedAt.addingTimeInterval(elapsed)
        for record in records where record.migrationTaskID == nil && resources.subjectPaths.contains(record.originalPath)
            && byPath[record.originalPath]?.count == 1 && record.createdAt >= startedAt && record.createdAt <= end {
            selected.insert(record.id)
        }
        return selected
    }
}
