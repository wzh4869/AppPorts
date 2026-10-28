import Foundation

/// Diagnostic facts only. They never authorize recovery or identify a flock owner.
struct OperationBlockage: LocalizedError, CustomNSError, Sendable {
    enum Reason: Int, Equatable, Sendable {
        case globalLockBusy = 1, signatureLockBusy, lockUnavailable, writerAdmission
        case signaturePreparation, backupRelocation, backupDependency, applicationTransfer, signatureRecordUnreadable, originalRetention
    }

    static let diagnosticFieldsKey = "AppPortsOperationDiagnosticFields"
    static var errorDomain: String { "AppPorts.OperationBlockage" }

    let reason: Reason
    var failureID = UUID()
    var applicationURL: URL? = nil
    var blockingOperationID: UUID? = nil
    var blockingPhase: String? = nil
    var recordURL: URL? = nil
    var lockURL: URL? = nil
    var systemErrorCode: Int32? = nil
    var admissionReason: String? = nil
    var underlyingError: NSError? = nil

    var diagnosticCode: String {
        switch reason {
        case .globalLockBusy: return "OPERATION-GLOBAL-LOCK-BUSY"
        case .signatureLockBusy: return "OPERATION-SIGNATURE-LOCK-BUSY"
        case .lockUnavailable: return "OPERATION-LOCK-UNAVAILABLE"
        case .writerAdmission: return "OPERATION-WRITER-ADMISSION-FAILED"
        case .signaturePreparation: return "SIGNATURE-PREPARATION-PENDING"
        case .backupRelocation: return "SIGNATURE-BACKUP-RELOCATION-PENDING"
        case .backupDependency: return "SIGNATURE-BACKUP-IN-USE"
        case .applicationTransfer: return "SIGNATURE-APPLICATION-TRANSFER-PENDING"
        case .signatureRecordUnreadable: return "SIGNATURE-RECORD-UNREADABLE"
        case .originalRetention: return "SIGNATURE-ORIGINAL-RETENTION-PENDING"
        }
    }

    var errorCode: Int { reason.rawValue }

    var errorDescription: String? {
        let message: String
        switch reason {
        case .globalLockBusy:
            message = "磁盘操作锁正被占用，本次未执行。请稍后重试；若持续出现，请导出诊断包。".localized
        case .signatureLockBusy:
            message = "签名操作锁正被占用，本次未执行。请稍后重试；若持续出现，请导出诊断包。".localized
        case .lockUnavailable:
            message = "无法访问操作锁文件，本次未执行。请检查访问权限或导出诊断包。".localized
        case .writerAdmission:
            message = admissionReason ?? "其他程序正在处理磁盘，请稍后重试。".localized
        case .signatureRecordUnreadable:
            message = "此应用的签名操作记录无法读取；已保留现有应用和操作记录，未继续更改：".localized + (recordURL?.path ?? "")
        case .originalRetention:
            message = "原始签名备份尚未保留完成，本次未执行。请稍后重试；若持续出现，请导出诊断包。".localized
        case .signaturePreparation:
            message = "此应用仍有未完成的签名操作，本次未执行。请稍后重试；若持续出现，请导出诊断包。".localized
        case .backupRelocation, .backupDependency, .applicationTransfer:
            message = "相关恢复材料仍被其他操作使用，本次未执行。请稍后重试；若持续出现，请导出诊断包。".localized
        }
        let subject = applicationURL.map { $0.lastPathComponent + "\n" } ?? ""
        let association = blockingOperationID.map {
            "\n\n" + String(format: "相关记录：%@".localized, $0.uuidString)
        } ?? ""
        return subject + message + association
    }

    var diagnosticFields: [String: String] {
        var fields = ["diagnostic_code": diagnosticCode, "failure_id": failureID.uuidString]
        fields["application_path"] = applicationURL?.path
        fields["blocking_operation_id"] = blockingOperationID?.uuidString
        fields["blocking_phase"] = blockingPhase
        fields["related_record_path"] = recordURL?.path
        fields["lock_path"] = lockURL?.path
        if lockURL != nil { fields["lock_owner"] = "unknown" }
        return fields
    }

    var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? diagnosticCode,
                                  Self.diagnosticFieldsKey: diagnosticFields]
        if let underlyingError { info[NSUnderlyingErrorKey] = underlyingError }
        else if let systemErrorCode {
            info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: Int(systemErrorCode))
        }
        if let lockURL { info[NSFilePathErrorKey] = lockURL.path }
        return info
    }

    static func pendingSignature(_ record: SignatureOperationRecord, reason: Reason = .signaturePreparation) -> Self {
        Self(reason: reason, applicationURL: record.applicationURL,
             blockingOperationID: record.id, blockingPhase: record.phase.rawValue)
    }
}
