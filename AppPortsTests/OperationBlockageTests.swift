import Foundation
import Testing
@testable import AppPorts

struct OperationBlockageTests {
    @Test("Pending signature diagnostics retain record identity through NSError bridging",
          arguments: [SignatureOperationRecord.Phase.preparing, .prepared, .switching, .cancelling])
    func pendingRecordFacts(phase: SignatureOperationRecord.Phase) throws {
        let app = URL(fileURLWithPath: "/Synthetic/Example.app")
        let record = SignatureOperationRecord(id: UUID(), kind: .sign, createdAt: Date(), applicationPath: app.path,
            applicationIdentity: DataPathIdentity(device: 1, inode: 1),
            applicationParentIdentity: DataPathIdentity(device: 1, inode: 2),
            version: SignatureAppVersion(bundleIdentifier: "com.example.app", buildVersion: "1", shortVersion: "1"),
            originalFingerprint: "synthetic", directoryPath: "/Synthetic/Candidate", phase: phase)
        let failure = OperationBlockage.pendingSignature(record)
        #expect(failure.reason == .signaturePreparation)
        #expect(failure.blockingOperationID == record.id)
        #expect(failure.blockingPhase == phase.rawValue)
        #expect(failure.applicationURL == app)
        #expect(failure.localizedDescription.contains(record.id.uuidString))
        #expect(failure.localizedDescription.contains(app.lastPathComponent))
        #expect(failure.diagnosticFields["lock_owner"] == nil)
        let native = failure as NSError
        #expect(native.domain == OperationBlockage.errorDomain)
        #expect(native.userInfo[OperationBlockage.diagnosticFieldsKey] as? [String: String] == failure.diagnosticFields)
    }
}
