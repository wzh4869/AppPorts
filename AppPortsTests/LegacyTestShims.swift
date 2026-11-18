import Foundation
@testable import AppPorts

extension DataMigrationWorkflow {
    static func run<Result>(
        validateBeforeMigration: () async throws -> Void = {},
        migrate: () async throws -> Result
    ) async throws -> Result {
        try await validateBeforeMigration()
        try Task.checkCancellation()
        return try await migrate()
    }
}

extension ContainerMountStore {
    func unfinishedTransfers() throws -> [DataTransferRecord] {
        try transfers()
    }
}
