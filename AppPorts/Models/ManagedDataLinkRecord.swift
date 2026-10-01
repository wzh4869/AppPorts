import Foundation

/// Persistent source index; survives deletion of the separately tracked retained original.
/// appName is display metadata only. Discovery ownership uses bundleIdentifier and source identity.
struct ManagedDataLinkRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { originalPath }
    let operationID: UUID
    let sourceID: String?
    let originalPath: String
    let destinationPath: String
    let destinationIdentity: DataPathIdentity
    let appName: String
    let bundleIdentifier: String?
    let dataDirType: String
    let createdAt: Date

    init(operationID: UUID, sourceID: String? = nil, originalPath: String, destinationPath: String,
         destinationIdentity: DataPathIdentity, appName: String, bundleIdentifier: String? = nil,
         dataDirType: String, createdAt: Date = Date()) {
        self.operationID = operationID
        self.sourceID = sourceID
        self.originalPath = originalPath
        self.destinationPath = destinationPath
        self.destinationIdentity = destinationIdentity
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.dataDirType = dataDirType
        self.createdAt = createdAt
    }

    var topologyEntries: [DataPathTopology.Entry] {
        [originalPath, destinationPath].map {
            .init(path: $0, origin: .link, operationID: operationID, volumeUUID: destinationIdentity.volumeUUID)
        }
    }
}
