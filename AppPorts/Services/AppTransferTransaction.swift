import AppKit
import Darwin
import Foundation
import Security

/// Fault injection stays at durable boundaries, so tests exercise the same
/// restart path used after a process termination rather than a second workflow.
struct AppTransferHooks {
    enum Checkpoint: String { case intentSaved, sourceProtectionSuspended, destinationProtectionSuspended, stageCreated, candidateCreated, copied, verified, beforeSwitch, destinationPublished, portalPrepared, entrySwitched, committed, beforeCleanup, afterCleanup }
    var checkpoint: ((Checkpoint, AppTransferRecord) throws -> Void)?
    var synchronizeCleanupParent: (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) }
    var synchronizeStagingParent: (URL) throws -> Void = { try DurableFileIO.syncDirectory(at: $0) }
}

/// Executes the application's own location journal. It never signs real code.
final class AppTransferTransaction {
    /// App transfers are product moves, not data-directory moves: the bundle's
    /// contents are already pinned by its code signature, so every pass here
    /// uses the product-integrity profile. See `TreeCopyProfile`.
    static let copyProfile: TreeCopyProfile = .appBundle

    typealias PortalBuilder = (AppTransferRecord, URL) throws -> Void
    typealias PortalMatcher = (URL, URL) -> Bool
    private let store: AppTransferStore
    private let fileManager: FileManager
    private let buildPortal: PortalBuilder
    private let portalMatches: PortalMatcher
    private let updateDock: AppMigrationService.DockShortcutUpdater
    private let runningApplications: () -> [AppRunningState.RunningApplication]
    private let facts: SignatureFactStore
    private let hooks: AppTransferHooks
    private let protection: AppUpdateProtectionStore

    init(store: AppTransferStore, fileManager: FileManager, facts: SignatureFactStore,
         buildPortal: @escaping PortalBuilder, portalMatches: @escaping PortalMatcher,
         updateDock: @escaping AppMigrationService.DockShortcutUpdater,
         runningApplications: @escaping () -> [AppRunningState.RunningApplication], hooks: AppTransferHooks) {
        self.store = store; self.fileManager = fileManager; self.facts = facts
        self.buildPortal = buildPortal; self.portalMatches = portalMatches; self.updateDock = updateDock
        self.runningApplications = runningApplications; self.hooks = hooks
        self.protection = AppUpdateProtectionStore(transferStore: store)
    }

    /// A later signature/location operation must not strand developer evidence
    /// in a committed transfer. Reconcile only its small identity facts while
    /// the caller holds the existing mutation lock; leave cleanup/Dock work alone.
    static func reconcileSignatureFacts(at app: URL, store: AppTransferStore, facts: SignatureFactStore) throws {
        guard try AppTransferStore.exists(store.directoryURL) else { return }
        let urls = try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "plist" }
        for url in urls {
            try Task.checkCancellation()
            // An unreadable unrelated transfer supplies no provenance and stays
            // visible as a journal diagnostic; it cannot block all signatures.
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  var record = try? store.record(id), record.operationID == id,
                  !record.signatureFactsCommitted, !record.signatureRelocations.isEmpty else { continue }
            let destination = URL(fileURLWithPath: record.activeDestinationPath).standardizedFileURL
            let related = record.signatureRelocations.contains { item in
                let path = item.relativePath.isEmpty ? destination : destination.appendingPathComponent(item.relativePath).standardizedFileURL
                return path.path == app.path
            }
            guard related, let activation = record.activation,
                  try AppTransferStore.exists(destination),
                  try DataPathIdentity.capture(destination).matchesFilesystemObject(activation.identity) else { continue }
            guard record.isSwitchComplete, record.switchIntentRecorded, record.hasCandidateBaseline else {
                throw CodeSigner.SigningError.operationInProgress
            }
            guard try DataPathIdentity.capture(destination.deletingLastPathComponent()).matchesFilesystemObject(activation.parentIdentity) else {
                throw CodeSigner.SigningError.applicationChanged
            }
            try store.recheckWriterAdmission()
            for item in record.signatureRelocations {
                let components = item.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard item.relativePath.isEmpty || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw CodeSigner.SigningError.snapshotInvalid
                }
                let target = item.relativePath.isEmpty ? destination : destination.appendingPathComponent(item.relativePath)
                try facts.commitRelocation(item.relocation, to: target)
            }
            record.signatureFactsCommitted = true
            try store.save(record)
        }
    }

    func start(app: AppItem, destination: URL, direction: AppTransferRecord.Direction,
               portalKind: String?, protectDestination: Bool, mayReplaceDestination: Bool,
               replacementChoice: AppMigrationService.ReplacementChoice? = nil,
               legacyPortals: [(URL, URL)], progress: FileCopier.ProgressHandler?) async throws -> AppTransferResult {
        let source = Self.canonical(app.path)
        let destination = Self.canonical(destination)
        guard source != destination, !Self.contains(source, destination), !Self.contains(destination, source),
              try SignatureSnapshot.info(at: source).st_mode & S_IFMT == S_IFDIR else {
            throw Self.failure("应用源与目标位置冲突，未执行转移。".localized, at: source)
        }
        var inventory = try store.inventory()
        try requireNoDamagedRecordConflict(inventory, source: source, destination: destination)
        for pending in inventory.records where pending.phase != .cancelled {
            if pending.sourcePath == source.path && pending.destinationPath == destination.path {
                if !pending.isSwitchComplete
                    || (pending.successorActivation == nil && (try? observeActivation(pending)) == true) {
                    // A resume would fail on its first manifest read with a raw
                    // file error; report the actionable reason instead.
                    try AppTransferJournalIntegrity.requireVerifiedManifests(for: pending, store: store)
                    return try await resume(pending.operationID, progress: progress)
                }
            }
            if !pending.isSwitchComplete && [pending.sourcePath, pending.destinationPath].contains(where: {
                Self.contains(URL(fileURLWithPath: $0), source) || Self.contains(source, URL(fileURLWithPath: $0))
                    || Self.contains(URL(fileURLWithPath: $0), destination) || Self.contains(destination, URL(fileURLWithPath: $0))
            }) {
                throw Self.failure("此位置的上次操作尚未完成。AppPorts 已保留数据并会继续尝试，请根据下面的原因处理后重试。".localized, at: source)
            }
        }
        // A preceding committed transfer may have stopped between its two
        // journal writes. Finish only that small handoff before moving its
        // active object again; conflicts in its old copies stay independent.
        try reconcilePredecessorActivations(at: source, records: inventory.records)
        inventory = try store.inventory()
        try requireNoDamagedRecordConflict(inventory, source: source, destination: destination)
        try requireNotRunning(source: source, applicationPaths: try applicationPaths(in: source, folder: app.usesFolderOperation))
        let sourceParent = source.deletingLastPathComponent()
        let destinationParent = destination.deletingLastPathComponent()
        let sourceIdentity = try DataPathIdentity.capture(source)
        let sourceParentIdentity = try DataPathIdentity.capture(sourceParent)
        let destinationParentIdentity = try DataPathIdentity.capture(destinationParent)
        let selectedDestinationIdentity = try AppTransferStore.exists(destination) ? DataPathIdentity.capture(destination) : nil
        guard selectedDestinationIdentity == nil || mayReplaceDestination else {
            throw Self.failure("目标已存在真实文件，无法覆盖。".localized, at: destination)
        }
        if let replacementChoice {
            guard source == replacementChoice.sourceURL, destination == replacementChoice.destinationURL,
                  replacementChoice.sourceIdentity.matchesFilesystemObject(sourceIdentity),
                  let selectedDestinationIdentity,
                  replacementChoice.destinationIdentity.matchesFilesystemObject(selectedDestinationIdentity) else {
                throw Self.failure("确认后源应用或目标应用已改变，请重新选择替换。".localized, at: destination)
            }
        }
        // Reusing a retained source must first finish that exact old cleanup.
        // It cannot be exchanged into a new stage while its original journal
        // still owns deletion at this name. Unrelated pending work stays alone.
        let consumedDestination = try finishDestinationCleanup(at: destination, records: inventory.records)
        try requireIdentity(sourceIdentity, at: source)
        try requireIdentity(sourceParentIdentity, at: sourceParent)
        try requireIdentity(destinationParentIdentity, at: destinationParent)
        if let consumedDestination {
            guard selectedDestinationIdentity.map({ $0.matchesFilesystemObject(consumedDestination) }) ?? true,
                  try !AppTransferStore.exists(destination) else {
                throw Self.failure("清理后目标位置出现了其他对象，请重新选择目标。".localized, at: destination)
            }
        } else if let selectedDestinationIdentity {
            // A vanished target is allowed only when this call actually
            // deleted the identity bound to the user's replacement choice.
            try requireIdentity(selectedDestinationIdentity, at: destination)
        } else if try AppTransferStore.exists(destination) {
            throw Self.failure("目标位置出现了其他对象，未覆盖。".localized, at: destination)
        }
        inventory = try store.inventory()
        try requireNoDamagedRecordConflict(inventory, source: source, destination: destination)
        let existing = selectedDestinationIdentity != nil && consumedDestination == nil
        let id = UUID()
        var record = AppTransferRecord(operationID: id, appName: app.name, direction: direction,
            usesFolderOperation: app.usesFolderOperation, sourcePath: source.path, destinationPath: destination.path,
            sourceIdentity: sourceIdentity, sourceParentIdentity: sourceParentIdentity,
            destinationParentIdentity: destinationParentIdentity, createdAt: Date(),
            stagePath: destinationParent.appendingPathComponent(".appports-transfer-" + id.uuidString).path,
            portalStagePath: direction == .migrate ? sourceParent.appendingPathComponent(".appports-entry-" + id.uuidString).path : nil,
            portalKind: portalKind, protectDestination: direction == .migrate && protectDestination)
        let predecessors = inventory.records.compactMap { pending -> AppTransferPredecessor? in
            guard pending.phase != .cancelled, pending.isSwitchComplete,
                  pending.usesFolderOperation == app.usesFolderOperation,
                  pending.activeDestinationPath == source.path,
                  let activation = pending.activation, (try? observeActivation(pending)) == true else { return nil }
            return .init(operationID: pending.operationID, activation: activation)
        }
        try requireIdentity(record.sourceIdentity, at: source)
        try requireIdentity(record.sourceParentIdentity, at: sourceParent)
        record.predecessorActivations = predecessors.isEmpty ? nil : predecessors
        if existing { record.existingDestinationIdentity = selectedDestinationIdentity }
        record.applicationPaths = try applicationPaths(in: source, folder: app.usesFolderOperation)
        for (index, pair) in legacyPortals.enumerated() {
            record.legacyPortals.append(.init(path: pair.0.path, externalPath: pair.1.path,
                identity: try DataPathIdentity.capture(pair.0), parentIdentity: try DataPathIdentity.capture(pair.0.deletingLastPathComponent()),
                baselineName: "portal-" + String(index), baseline: try captureBaseline(pair.0), removalID: UUID()))
        }
        // Both original objects' exact protection tokens belong to the initial
        // intent. A crash anywhere in either flag loop therefore leaves enough
        // evidence for cancellation; a post-unlock status save is not required.
        record.protectionRecovery = try captureProtectionRecovery(for: record)
        try store.save(record)
        let journal = Journal(record, store: store)
        do {
            try checkpoint(.intentSaved, journal)
            // Suspend only the protection bits first: a locked tree cannot be
            // walked for a baseline, so this must precede every read. The tokens
            // for it are already durable in the record.
            try suspendPreparationProtection(journal)
            // With flags suspended, everything that reads the tree happens now.
            // The replaced target's baseline in particular must be durable before
            // any content moves: a resume cannot tell its authorized contents from
            // later writes to the same inode, so it would have to refuse, and
            // refusing with a copy already in flight strands both sides.
            if existing {
                do {
                    try store.writeBaseline(try captureBaseline(destination), named: "existing", operationID: id)
                } catch {
                    // Nothing was copied yet: end this intent instead of leaving a
                    // record whose only outcome is the refusal on the next attempt.
                    throw Self.failure("无法记录替换目标的初始状态，本次操作尚未开始，未改动任何一方：".localized
                        + error.localizedDescription, at: destination)
                }
                journal.record.hasExistingDestinationBaseline = true
                try journal.save()
            }
            for relative in record.applicationPaths {
                let url = relative.isEmpty ? source : source.appendingPathComponent(relative)
                let valid = try signatureIsValid(at: url)
                if let relocation = try facts.captureRelocation(from: url, transferStore: store) {
                    journal.record.signatureRelocations.append(.init(relativePath: relative, relocation: relocation))
                }
                journal.record.signatureChecks[relative] = valid
            }
            try journal.save()
            return try await continueTransfer(journal, progress: progress)
        } catch { return try handle(error, journal: journal) }
    }

    private func requireNoDamagedRecordConflict(_ inventory: AppTransferStore.Inventory, source: URL, destination: URL) throws {
        for issue in inventory.issues where issue.knownPaths.contains(where: { path in
            let known = Self.canonical(URL(fileURLWithPath: path))
            return Self.contains(known, source) || Self.contains(source, known)
                || Self.contains(known, destination) || Self.contains(destination, known)
        }) {
            throw Self.failure("历史应用转移记录损坏，AppPorts 暂时无法确认此位置的数据归属。数据已保留，本次操作尚未开始。".localized, at: issue.url)
        }
    }

    private func finishDestinationCleanup(at destination: URL, records: [AppTransferRecord]) throws -> DataPathIdentity? {
        var consumed: DataPathIdentity?
        for record in records where record.phase != .cancelled {
            let indices = record.cleanupItems.indices.filter {
                !record.cleanupItems[$0].completed && record.cleanupItems[$0].path == destination.path
            }
            guard !indices.isEmpty else { continue }
            let journal = Journal(record, store: store)
            let recordURL = store.directoryURL.appendingPathComponent(record.operationID.uuidString + ".plist")
            for index in indices {
                do {
                    guard record.isSwitchComplete, record.phase == .committed, record.signatureFactsCommitted,
                          record.predecessorActivations?.isEmpty != false else {
                        throw Self.failure("旧转移的提交或签名状态仍待处理。".localized, at: recordURL)
                    }
                    if let deleted = try cleanup(index, journal: journal) { consumed = deleted }
                } catch {
                    journal.record.cleanupItems[index].lastError = error.localizedDescription
                    try? journal.save()
                    throw Self.failure("此位置的上次操作尚未完成。AppPorts 已保留数据并会继续尝试，请根据下面的原因处理后重试。".localized
                        + "\n" + destination.path + "\n" + error.localizedDescription, at: recordURL)
                }
            }
        }
        return consumed
    }

    private func reconcilePredecessorActivations(at source: URL, records: [AppTransferRecord]) throws {
        for record in records where record.phase != .cancelled && record.isSwitchComplete
            && record.activeDestinationPath == source.path && record.predecessorActivations?.isEmpty == false {
            guard (try? observeActivation(record)) == true else { continue }
            let journal = Journal(record, store: store)
            if record.phase != .committed {
                try requireParents(record)
                try recordCommit(journal)
            }
            try commitPredecessorActivations(journal)
        }
    }

    func resume(_ id: UUID, progress: FileCopier.ProgressHandler?) async throws -> AppTransferResult {
        let journal = Journal(try store.record(id), store: store)
        try AppTransferJournalIntegrity.requireVerifiedManifests(for: journal.record, store: store)
        if journal.record.phase == .cancelled { return try reconcileCancelled(journal) }
        do { return try await continueTransfer(journal, progress: progress) }
        catch { return try handle(error, journal: journal) }
    }

    func pending() throws -> [AppTransferRecord] {
        try pendingInspection().records
    }

    func pendingInspection() throws -> AppTransferStore.Inventory {
        var inventory = try store.inventory()
        inventory.records = inventory.records.map { original in
            var record = original
            if !record.isSwitchComplete, (try? observeActivation(record)) == true {
                record.committedAt = Date()
                record.recoverableReason = "应用位置已切换，完成记录待写入。".localized
            }
            return record
        }
        return inventory
    }

    func cancel(_ id: UUID) throws -> AppTransferResult {
        try store.recheckWriterAdmission()
        let journal = Journal(try store.record(id), store: store)
        let record = journal.record
        guard !record.isSwitchComplete, try !observeActivation(record) else {
            throw Self.failure("应用位置已经切换，请继续完成清理。".localized, at: URL(fileURLWithPath: record.activeDestinationPath))
        }
        if record.phase == .cancelled { return try reconcileCancelled(journal) }
        try requireParents(record)
        let source = URL(fileURLWithPath: record.sourcePath)
        try requireIdentity(record.sourceIdentity, at: source)
        // An external candidate may already have been published while the
        // original local application remained intact. Undo only that proven
        // publication, never a location whose local entry already switched.
        if try candidateIsPublished(record) {
            try verifyCandidate(record, at: URL(fileURLWithPath: record.destinationPath))
            let destination = URL(fileURLWithPath: record.destinationPath)
            try store.recheckWriterAdmission()
            if let old = record.existingDestinationIdentity {
                try requireIdentity(old, at: record.candidateURL)
                try verifyBaseline("existing", record: record, at: record.candidateURL)
                try Self.exchange(destination, record.candidateURL)
            } else {
                try Self.moveExclusively(destination, record.candidateURL)
            }
            try DurableFileIO.syncDirectory(at: destination.deletingLastPathComponent())
            try DurableFileIO.syncDirectory(at: URL(fileURLWithPath: record.stagePath))
        }
        if try AppTransferStore.exists(record.candidateURL), record.candidateIdentity == nil {
            journal.record.unclaimedPaths.append(record.candidateURL.path)
        } else {
            try cancelOwnedCandidate(journal)
        }
        if let portal = record.stagedPortalURL, try AppTransferStore.exists(portal) {
            if let identity = record.portalIdentity {
                try requireIdentity(identity, at: portal)
                try removeFreshOwned(portal)
            } else { journal.record.unclaimedPaths.append(portal.path) }
        }
        try removeEmptyStage(URL(fileURLWithPath: record.stagePath), identity: record.stageIdentity,
                             parentIdentity: record.destinationParentIdentity, journal: journal)
        if let path = record.portalStagePath {
            try removeEmptyStage(URL(fileURLWithPath: path), identity: record.portalStageIdentity,
                                 parentIdentity: record.sourceParentIdentity, journal: journal)
        }
        let recovery = try protectionRecovery(journal)
        if let token = recovery.source { try protection.commitSameObjectMove(token, to: source) }
        if let token = recovery.existingDestination {
            try protection.commitSameObjectMove(token, to: URL(fileURLWithPath: record.destinationPath))
        }
        journal.record.phase = .cancelled
        journal.record.recoverableReason = nil
        try journal.save()
        let result = result(journal.record)
        if journal.record.unclaimedPaths.isEmpty { try store.remove(id) }
        return result
    }

    private func continueTransfer(_ journal: Journal, progress: FileCopier.ProgressHandler?) async throws -> AppTransferResult {
        try requireParents(journal.record)
        if try observeActivation(journal.record) {
            return try finishCommitted(journal)
        }
        guard !journal.record.isSwitchComplete else {
            throw Self.failure("记录中的活动应用已被替换或磁盘尚未连接，保留所有旧副本。".localized,
                               at: URL(fileURLWithPath: journal.record.activeDestinationPath))
        }
        let source = URL(fileURLWithPath: journal.record.sourcePath)
        try requireIdentity(journal.record.sourceIdentity, at: source)
        try requireNotRunning(source: source, applicationPaths: journal.record.applicationPaths)
        // Until an existing target's baseline is durable we cannot distinguish
        // its originally authorized contents from later writes to that inode.
        // Cancellation preserves it and lets the user make a fresh selection.
        if !journal.record.hasExistingDestinationBaseline, journal.record.existingDestinationIdentity != nil {
            let destination = URL(fileURLWithPath: journal.record.destinationPath)
            throw Self.failure("替换目标的初始核验记录尚未保存，已保留双方；请取消此尝试后重新选择目标。".localized, at: destination)
        }
        if journal.record.applicationPaths.contains(where: { journal.record.signatureChecks[$0] == nil }) {
            for relative in journal.record.applicationPaths where journal.record.signatureChecks[relative] == nil {
                let url = relative.isEmpty ? source : source.appendingPathComponent(relative)
                let valid = try signatureIsValid(at: url)
                if let relocation = try facts.captureRelocation(from: url, transferStore: store) {
                    journal.record.signatureRelocations.append(.init(relativePath: relative, relocation: relocation))
                }
                journal.record.signatureChecks[relative] = valid
            }
            try journal.save()
        }
        if !journal.record.hasCandidateBaseline {
            try await prepareCandidate(journal, progress: progress)
        }
        try verifySource(journal.record)
        let published = try candidateIsPublished(journal.record)
        try verifyCandidate(journal.record, at: published ? URL(fileURLWithPath: journal.record.destinationPath) : journal.record.candidateURL)
        try requireNotRunning(source: source, applicationPaths: journal.record.applicationPaths)
        try Task.checkCancellation()
        try checkpoint(.beforeSwitch, journal)
        // The callback is an intentional race boundary in tests. Production
        // performs the same final source/process checks immediately afterwards.
        try verifySource(journal.record)
        try requireNotRunning(source: source, applicationPaths: journal.record.applicationPaths)
        journal.record.phase = .switching
        journal.record.switchIntentRecorded = true
        try journal.save()
        if journal.record.direction == .migrate {
            try publishExternalCandidate(journal)
            try preparePortal(journal)
            try verifySource(journal.record)
            try requireNotRunning(source: source, applicationPaths: journal.record.applicationPaths)
            try Task.checkCancellation()
            guard let portal = journal.record.stagedPortalURL, let identity = journal.record.portalIdentity else {
                throw Self.failure("本地入口暂存记录不完整。".localized, at: source)
            }
            try requireIdentity(identity, at: portal)
            guard portalMatches(portal, URL(fileURLWithPath: journal.record.destinationPath)) else {
                throw Self.failure("暂存入口已改变，未切换应用。".localized, at: portal)
            }
            try store.recheckWriterAdmission()
            try Self.exchange(source, portal)
        } else {
            let destination = URL(fileURLWithPath: journal.record.destinationPath)
            try verifyExistingDestination(journal.record)
            try store.recheckWriterAdmission()
            if journal.record.existingDestinationIdentity != nil { try Self.exchange(destination, journal.record.candidateURL) }
            else { try Self.moveExclusively(journal.record.candidateURL, destination) }
        }
        try checkpoint(.entrySwitched, journal)
        return try finishCommitted(journal)
    }

    private func prepareCandidate(_ journal: Journal, progress: FileCopier.ProgressHandler?) async throws {
        let source = URL(fileURLWithPath: journal.record.sourcePath)
        try suspendPreparationProtection(journal)
        try ensureStage(journal, portal: false)
        try cancelOwnedCandidate(journal)
        journal.record.phase = .copying
        journal.record.hasSourceBaseline = false
        journal.record.candidateIdentity = nil
        try journal.save()
        // An application bundle is a replaceable product whose contents are
        // already pinned by its code signature, so it uses the product-integrity
        // profile instead of the data-directory content-addressed one.
        let snapshot = try await TreeCopySession(profile: .appBundle).copy(from: source, to: journal.record.candidateURL,
            finalDestination: URL(fileURLWithPath: journal.record.destinationPath),
            preparedHandler: { snapshot in
                try journal.store.writeBaseline(.init(tree: snapshot, linkTarget: nil, linkIdentity: nil,
                    volumeUUID: journal.record.sourceIdentity.volumeUUID), named: "source", operationID: journal.record.operationID)
                journal.record.hasSourceBaseline = true
                try journal.save()
            }, destinationCreatedHandler: { identity in
                try self.checkpoint(.candidateCreated, journal)
                journal.record.candidateIdentity = identity
                try journal.save()
            }, progressHandler: progress)
        try checkpoint(.copied, journal)
        // Preserve the historical application-only quarantine removal. It is
        // the sole allowed metadata difference and never touches the source.
        let candidate = journal.record.candidateURL
        if journal.record.direction == .migrate {
            for entry in snapshot.entries where entry.extendedAttributes["com.apple.quarantine"] != nil {
                let url = entry.path.isEmpty ? candidate : candidate.appendingPathComponent(entry.path)
                if removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                    throw Self.posix(url)
                }
            }
        }
        let expected = journal.record.direction == .migrate ? withoutQuarantine(snapshot) : snapshot
        try TreeCopySession.verifyCopy(at: candidate, against: expected, profile: Self.copyProfile)
        try verifySignatures(journal.record, root: candidate)
        try DurableFileIO.syncTree(at: candidate, barrier: Self.copyProfile.syncBarrier)
        try store.writeBaseline(try captureBaseline(candidate), named: "candidate", operationID: journal.record.operationID)
        journal.record.hasCandidateBaseline = true
        journal.record.phase = .verified
        journal.record.recoverableReason = nil
        try journal.save()
        try checkpoint(.verified, journal)
    }

    private func captureProtectionRecovery(for record: AppTransferRecord) throws -> AppTransferProtectionRecovery {
        try adoptLegacyLockIfNeeded(for: record)
        let source = URL(fileURLWithPath: record.sourcePath)
        try requireIdentity(record.sourceIdentity, at: source)
        let sourceToken = try protection.captureForExchange(at: source)
        try requireIdentity(record.sourceIdentity, at: source)
        var destinationToken: AppUpdateProtectionRelocation?
        if let identity = record.existingDestinationIdentity {
            let destination = URL(fileURLWithPath: record.destinationPath)
            try requireIdentity(identity, at: destination)
            destinationToken = try protection.captureForExchange(at: destination)
            try requireIdentity(identity, at: destination)
        }
        let recovery = AppTransferProtectionRecovery(source: sourceToken, existingDestination: destinationToken)
        try validateProtectionRecovery(recovery, for: record)
        return recovery
    }

    /// v1.9.0 locked external copies with `chflags -R uchg` and recorded nothing,
    /// so 1.9.1 saw those bits as somebody else's and the verified copier failed
    /// closed on them. Only a restore needs this: a migration reads the local app,
    /// which AppPorts never locks. Record the whole tree's immutable bits first,
    /// then clear them through the normal suspension path.
    private func adoptLegacyLockIfNeeded(for record: AppTransferRecord) throws {
        guard record.direction == .restore else { return }
        let source = URL(fileURLWithPath: record.sourcePath)
        // The root is not a reliable indicator: an app that was updated after
        // being locked can have an unlocked root with locked children. Record the
        // whole tree whenever anything in it is still locked.
        let destination = URL(fileURLWithPath: record.destinationPath)
        _ = try protection.adoptLegacyLock(source, evidence: .init(
            managedLocalEntry: portalMatches(destination, source) ? destination : nil,
            sameApplicationSource: nil))
    }

    private func protectionRecovery(_ journal: Journal) throws -> AppTransferProtectionRecovery {
        if var recovery = journal.record.protectionRecovery {
            // A journal written by the first attempt at a v1.9.0-locked tree
            // recorded empty tokens. Adopt now instead of leaving the resume
            // path to fail at the same flag check forever.
            let source = URL(fileURLWithPath: journal.record.sourcePath)
            let locked = (try? SignatureSnapshot.info(at: source).st_flags & UInt32(UF_IMMUTABLE)) ?? 0 != 0
            if recovery.source == nil, locked {
                try adoptLegacyLockIfNeeded(for: journal.record)
                recovery = try captureProtectionRecovery(for: journal.record)
                journal.record.protectionRecovery = recovery
                try journal.save()
            }
            try validateProtectionRecovery(recovery, for: journal.record)
            return recovery
        }
        // Older v3 journals have no token container. Recover only exact valid
        // protection records for the recorded objects, before changing flags.
        let recovery = try captureProtectionRecovery(for: journal.record)
        journal.record.protectionRecovery = recovery
        try journal.save()
        return recovery
    }

    private func validateProtectionRecovery(_ recovery: AppTransferProtectionRecovery, for record: AppTransferRecord) throws {
        if record.sourceProtectionSuspended && recovery.source == nil {
            throw Self.failure("应用更新保护来源无法确认。".localized, at: URL(fileURLWithPath: record.sourcePath))
        }
        if let token = recovery.source {
            guard token.path == record.sourcePath, token.identity.matchesFilesystemObject(record.sourceIdentity) else {
                throw Self.failure("应用更新保护来源无法确认。".localized, at: URL(fileURLWithPath: record.sourcePath))
            }
        }
        if let token = recovery.existingDestination {
            guard token.path == record.destinationPath, let identity = record.existingDestinationIdentity,
                  token.identity.matchesFilesystemObject(identity) else {
                throw Self.failure("应用更新保护来源无法确认。".localized, at: URL(fileURLWithPath: record.destinationPath))
            }
        }
    }

    private func suspendPreparationProtection(_ journal: Journal) throws {
        let recovery = try protectionRecovery(journal)
        if let token = recovery.source {
            try protection.suspendForExchange(token, at: URL(fileURLWithPath: journal.record.sourcePath))
            try checkpoint(.sourceProtectionSuspended, journal)
            journal.record.sourceProtectionSuspended = true
        }
        if let token = recovery.existingDestination {
            try protection.suspendForExchange(token, at: URL(fileURLWithPath: journal.record.destinationPath))
            try checkpoint(.destinationProtectionSuspended, journal)
        }
        try journal.save()
    }

    private func publishExternalCandidate(_ journal: Journal) throws {
        if try candidateIsPublished(journal.record) { return }
        try verifyExistingDestination(journal.record)
        let destination = URL(fileURLWithPath: journal.record.destinationPath)
        try store.recheckWriterAdmission()
        if journal.record.existingDestinationIdentity != nil { try Self.exchange(destination, journal.record.candidateURL) }
        else { try Self.moveExclusively(journal.record.candidateURL, destination) }
        try DurableFileIO.syncDirectory(at: destination.deletingLastPathComponent())
        try syncStageIfPresent(URL(fileURLWithPath: journal.record.stagePath), identity: journal.record.stageIdentity, record: journal.record)
        try checkpoint(.destinationPublished, journal)
    }

    private func preparePortal(_ journal: Journal) throws {
        try ensureStage(journal, portal: true)
        guard let portal = journal.record.stagedPortalURL else { throw CocoaError(.fileWriteInvalidFileName) }
        if try AppTransferStore.exists(portal) {
            guard let identity = journal.record.portalIdentity else {
                throw Self.failure("入口暂存对象尚无持久归属记录，可以取消此尝试并保留该对象。".localized, at: portal)
            }
            try requireIdentity(identity, at: portal)
        } else {
            try buildPortal(journal.record, portal)
            journal.record.portalIdentity = try DataPathIdentity.capture(portal)
            try journal.save()
        }
        guard portalMatches(portal, URL(fileURLWithPath: journal.record.destinationPath)) else {
            throw Self.failure("创建的入口并未指向本次应用目标。".localized, at: portal)
        }
        if try SignatureSnapshot.info(at: portal).st_mode & S_IFMT != S_IFLNK {
            try DurableFileIO.syncTree(at: portal)
        }
        try DurableFileIO.syncDirectory(at: portal.deletingLastPathComponent())
        try checkpoint(.portalPrepared, journal)
    }

    private func recordCommit(_ journal: Journal) throws {
        guard try observeActivation(journal.record) else {
            throw Self.failure("无法确认本次应用入口已切换，保留双方。".localized, at: URL(fileURLWithPath: journal.record.activeDestinationPath))
        }
        if journal.record.committedAt == nil { journal.record.committedAt = Date() }
        // These writes are also retried after a switched-but-unrecorded crash.
        // Never replay root metadata or compare active contents to an old hash.
        try DurableFileIO.syncDirectory(at: URL(fileURLWithPath: journal.record.destinationPath).deletingLastPathComponent())
        try syncStageIfPresent(URL(fileURLWithPath: journal.record.stagePath), identity: journal.record.stageIdentity, record: journal.record)
        if let portalStage = journal.record.portalStagePath {
            try DurableFileIO.syncDirectory(at: URL(fileURLWithPath: journal.record.sourcePath).deletingLastPathComponent())
            try syncStageIfPresent(URL(fileURLWithPath: portalStage), identity: journal.record.portalStageIdentity, record: journal.record)
        }
        try prepareCleanupItems(journal)
        journal.record.phase = .committed
        journal.record.recoverableReason = nil
        try journal.save()
        try checkpoint(.committed, journal)
    }

    private func commitPredecessorActivations(_ journal: Journal) throws {
        guard let predecessors = journal.record.predecessorActivations, !predecessors.isEmpty else { return }
        guard journal.record.phase == .committed, journal.record.isSwitchComplete,
              let activation = journal.record.activation, activation.operationID == journal.record.operationID,
              try observeActivation(journal.record) else {
            throw Self.failure("活动应用身份无法确认，已暂停清理。".localized,
                               at: URL(fileURLWithPath: journal.record.activeDestinationPath))
        }
        for reference in predecessors {
            guard reference.operationID != journal.record.operationID,
                  reference.activation.path == journal.record.sourcePath,
                  reference.activation.parentIdentity.matchesFilesystemObject(journal.record.sourceParentIdentity) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let url = store.directoryURL.appendingPathComponent(reference.operationID.uuidString + ".plist")
            // A predecessor can finish independently while this handoff is
            // waiting. An unreadable existing record must still be retried.
            guard try AppTransferStore.exists(url) else { continue }
            var predecessor = try store.record(reference.operationID)
            guard predecessor.isSwitchComplete, predecessor.phase != .cancelled,
                  predecessor.activation == reference.activation || predecessor.successorActivation == activation else {
                throw Self.failure("应用转移记录已改变，已保留内容。".localized, at: url)
            }
            // Admission bound the reference to this exact source and parent;
            // the normal copy and pre-switch checks then verified its contents.
            // Old-copy conflicts after that switch must not prevent this
            // bookkeeping or a later move of the new active application.
            predecessor.successorActivation = activation
            try store.save(predecessor)
            guard try observeActivation(journal.record) else {
                throw Self.failure("活动应用身份无法确认，已暂停清理。".localized,
                                   at: URL(fileURLWithPath: activation.path))
            }
        }
        // Re-save an already matching predecessor on retry, since its earlier
        // write may have renamed the file but failed its directory sync. Only
        // the successful second journal write releases source deletion.
        journal.record.predecessorActivations = nil
        do { try journal.save() }
        catch { journal.record.predecessorActivations = predecessors; throw error }
        guard try observeActivation(journal.record) else {
            throw Self.failure("活动应用身份无法确认，已暂停清理。".localized,
                               at: URL(fileURLWithPath: activation.path))
        }
    }

    private func finishCommitted(_ journal: Journal) throws -> AppTransferResult {
        try recordCommit(journal)
        try commitPredecessorActivations(journal)
        var warnings: [String] = []
        if !journal.record.signatureFactsCommitted {
            do {
                let destination = URL(fileURLWithPath: journal.record.activeDestinationPath)
                for item in journal.record.signatureRelocations {
                    try facts.commitRelocation(item.relocation,
                        to: item.relativePath.isEmpty ? destination : destination.appendingPathComponent(item.relativePath))
                }
                journal.record.signatureFactsCommitted = true
                try journal.save()
            } catch { warnings.append(error.localizedDescription) }
        }
        if !journal.record.dockSynchronized {
            do {
                try requireActive(journal.record)
                let source = URL(fileURLWithPath: journal.record.sourcePath)
                let destination = URL(fileURLWithPath: journal.record.activeDestinationPath)
                if source != destination { _ = try updateDock(source, destination) }
                try requireActive(journal.record)
                journal.record.dockSynchronized = true
                try journal.save()
            } catch { warnings.append(error.localizedDescription) }
        }
        for index in journal.record.legacyPortals.indices {
            do { try finishLegacyPortal(index, journal: journal) }
            catch { journal.record.legacyPortals[index].lastError = error.localizedDescription; warnings.append(error.localizedDescription) }
        }
        // Facts must follow the verified installation before its source is
        // deleted, otherwise a failed fact write could lose developer identity.
        if journal.record.signatureFactsCommitted {
            for index in journal.record.cleanupItems.indices where !journal.record.cleanupItems[index].completed {
                do { try cleanupWithVerificationRetry(index, journal: journal) }
                catch { journal.record.cleanupItems[index].lastError = error.localizedDescription; warnings.append(error.localizedDescription) }
            }
        }
        if journal.record.protectDestination && !journal.record.destinationProtected && journal.record.successorActivation == nil {
            do {
                try protection.protect(URL(fileURLWithPath: journal.record.destinationPath))
                journal.record.destinationProtected = true
                try journal.save()
            } catch { warnings.append(error.localizedDescription) }
        }
        if journal.record.cleanupItems.allSatisfy(\.completed) {
            do {
                try removeEmptyStage(URL(fileURLWithPath: journal.record.stagePath), identity: journal.record.stageIdentity,
                                     parentIdentity: journal.record.destinationParentIdentity, journal: journal)
                if let path = journal.record.portalStagePath {
                    try removeEmptyStage(URL(fileURLWithPath: path), identity: journal.record.portalStageIdentity,
                                         parentIdentity: journal.record.sourceParentIdentity, journal: journal)
                }
                journal.record.stagingCleanupComplete = journal.record.unclaimedPaths.isEmpty
                try journal.save()
            } catch { warnings.append(error.localizedDescription) }
        }
        journal.record.recoverableReason = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        do { try journal.save() } catch { warnings.append(error.localizedDescription) }
        var final = result(journal.record, warnings: warnings)
        if final.isComplete {
            do { try store.remove(journal.record.operationID) }
            catch {
                warnings.append(error.localizedDescription)
                final = result(journal.record, warnings: warnings,
                    extraTasks: [.init(kind: .recordCommit, path: store.directoryURL.path, message: "转移已完成，记录收尾待重试。".localized)])
            }
        }
        return final
    }

    private func prepareCleanupItems(_ journal: Journal) throws {
        guard journal.record.cleanupItems.isEmpty else { return }
        let record = journal.record
        let sourceURL = record.direction == .migrate ? record.stagedPortalURL! : URL(fileURLWithPath: record.sourcePath)
        journal.record.cleanupItems.append(.init(id: UUID(), role: .source, path: sourceURL.path,
            originalPath: record.sourcePath, identity: record.sourceIdentity,
            parentIdentity: try DataPathIdentity.capture(sourceURL.deletingLastPathComponent()), baselineName: "source"))
        if let existing = record.existingDestinationIdentity {
            journal.record.cleanupItems.append(.init(id: UUID(), role: record.direction == .restore ? .originalPortal : .replacedDestination,
                path: record.candidateURL.path, originalPath: record.destinationPath, identity: existing,
                parentIdentity: try DataPathIdentity.capture(record.candidateURL.deletingLastPathComponent()), baselineName: "existing"))
        }
    }

    private func cleanupWithVerificationRetry(_ index: Int, journal: Journal) throws {
        do {
            try cleanup(index, journal: journal)
        } catch let error as TreeCopyError {
            switch error {
            case .sourceChanged, .verificationFailed:
                // A concurrent metadata update can invalidate one observation.
                // Retry the same durable baseline before reporting a pending
                // operation; never adopt the changed tree as a new baseline.
                try Task.checkCancellation()
                try cleanup(index, journal: journal)
            default:
                throw error
            }
        }
    }

    @discardableResult
    private func cleanup(_ index: Int, journal: Journal) throws -> DataPathIdentity? {
        var item = journal.record.cleanupItems[index]
        let url = URL(fileURLWithPath: item.path)
        try requireActive(journal.record)
        try requireIdentity(item.parentIdentity, at: url.deletingLastPathComponent())
        let remaining = try TreeCopySession.retainedRemovalURL(at: url, removalID: item.id)
        if let remaining {
            try requireIdentity(item.identity, at: remaining)
            try requireOldCopyNotRunning(item, record: journal.record)
            let baseline = try store.baseline(item.baselineName, operationID: journal.record.operationID)
            if !item.deletionStarted {
                try verify(baseline, at: remaining, unchanged: true)
                item.deletionStarted = true
                journal.record.cleanupItems[index] = item
                try journal.save()
            }
            try checkpoint(.beforeCleanup, journal)
            try requireActive(journal.record)
            try requireOldCopyNotRunning(item, record: journal.record)
            try remove(baseline, at: url, identity: item.identity, removalID: item.id, partial: true)
        } else if !item.deletionStarted {
            throw Self.failure("旧副本已不在记录位置，未将其视为已清理。".localized, at: url)
        }
        // A missing name proves neither that a prior unlink was durable nor
        // that the parent is still the recorded directory. Cold retries owe
        // this same barrier before either the protection fact or journal exits.
        try finishRemovalBarrier(parent: url.deletingLastPathComponent(), identity: item.parentIdentity, record: journal.record)
        try checkpoint(.afterCleanup, journal)
        if item.role == .source || item.role == .replacedDestination {
            try protection.forget(path: item.originalPath, identity: item.identity)
        }
        journal.record.cleanupItems[index].completed = true
        journal.record.cleanupItems[index].lastError = nil
        try journal.save()
        // A missing name can finish a prior deletion, but cannot prove that a
        // replacement confirmation's target was consumed by this call.
        return remaining == nil ? nil : item.identity
    }

    private func finishLegacyPortal(_ index: Int, journal: Journal) throws {
        var portal = journal.record.legacyPortals[index]
        let local = URL(fileURLWithPath: portal.path)
        if !portal.retired {
            try requireActive(journal.record)
            try requireIdentity(portal.parentIdentity, at: local.deletingLastPathComponent())
            if let remaining = try TreeCopySession.retainedRemovalURL(at: local, removalID: portal.removalID) {
                try requireIdentity(portal.identity, at: remaining)
                let baseline = portal.baseline
                if !portal.deletionStarted {
                    guard portalMatches(local, URL(fileURLWithPath: portal.externalPath)) else {
                        throw Self.failure("旧入口已改变，未删除。".localized, at: local)
                    }
                    try verify(baseline, at: local, unchanged: true)
                    portal.deletionStarted = true
                    journal.record.legacyPortals[index] = portal
                    try journal.save()
                }
                try remove(baseline, at: local, identity: portal.identity, removalID: portal.removalID, partial: true)
            } else if !portal.deletionStarted {
                throw Self.failure("旧入口已离开记录位置，未自动认定已清理。".localized, at: local)
            }
            try finishRemovalBarrier(parent: local.deletingLastPathComponent(), identity: portal.parentIdentity, record: journal.record)
            journal.record.legacyPortals[index].retired = true
            try journal.save()
        }
        if !journal.record.legacyPortals[index].dockSynchronized {
            try requireActive(journal.record)
            let restored = URL(fileURLWithPath: journal.record.activeDestinationPath)
                .appendingPathComponent(URL(fileURLWithPath: portal.externalPath).lastPathComponent)
            if local != restored { _ = try updateDock(local, restored) }
            try requireActive(journal.record)
            journal.record.legacyPortals[index].dockSynchronized = true
            journal.record.legacyPortals[index].lastError = nil
            try journal.save()
        }
    }

    private func finishRemovalBarrier(parent: URL, identity: DataPathIdentity, record: AppTransferRecord) throws {
        try requireIdentity(identity, at: parent)
        try hooks.synchronizeCleanupParent(parent)
        try requireIdentity(identity, at: parent)
        try requireActive(record)
    }

    private func observeActivation(_ record: AppTransferRecord) throws -> Bool {
        guard record.switchIntentRecorded, record.hasCandidateBaseline, let activation = record.activation,
              record.successorActivation == nil || record.isSwitchComplete else { return false }
        let destination = URL(fileURLWithPath: activation.path)
        try requireIdentity(activation.parentIdentity, at: destination.deletingLastPathComponent())
        guard try AppTransferStore.exists(destination) else { return false }
        if try !activation.identity.matchesFilesystemObject(DataPathIdentity.capture(destination)) {
            // A later AppPorts signature/official repair swaps the app root.
            // Its current fact explicitly preserves the installation identity;
            // this only admits old-copy cleanup, never a different same-ID app.
            guard record.isSwitchComplete, record.signatureFactsCommitted, !record.usesFolderOperation,
                  let original = record.signatureRelocations.first(where: { $0.relativePath.isEmpty })?.relocation.fact,
                  let current = try facts.currentFact(at: destination, verifyContent: true),
                  current.installationID == original.installationID,
                  current.version == original.version,
                  current.originalDeveloper == original.originalDeveloper,
                  current.originalFingerprint == original.originalFingerprint else { return false }
        }
        if record.direction == .restore || record.isSwitchComplete { return true }
        let local = URL(fileURLWithPath: record.sourcePath)
        guard let portal = record.portalIdentity, try AppTransferStore.exists(local),
              try portal.matchesFilesystemObject(DataPathIdentity.capture(local)), portalMatches(local, destination) else { return false }
        return true
    }

    private func candidateIsPublished(_ record: AppTransferRecord) throws -> Bool {
        guard record.direction == .migrate, record.switchIntentRecorded, let identity = record.candidateIdentity else { return false }
        let destination = URL(fileURLWithPath: record.destinationPath)
        return try AppTransferStore.exists(destination) && identity.matchesFilesystemObject(DataPathIdentity.capture(destination))
    }

    private func requireActive(_ record: AppTransferRecord) throws {
        try requireParents(record)
        guard try observeActivation(record) else {
            throw Self.failure("活动应用身份无法确认，已暂停清理。".localized, at: URL(fileURLWithPath: record.activeDestinationPath))
        }
    }

    private func requireParents(_ record: AppTransferRecord) throws {
        try requireIdentity(record.sourceParentIdentity, at: URL(fileURLWithPath: record.sourcePath).deletingLastPathComponent())
        try requireIdentity(record.destinationParentIdentity, at: URL(fileURLWithPath: record.destinationPath).deletingLastPathComponent())
    }

    private func verifySource(_ record: AppTransferRecord) throws {
        try requireIdentity(record.sourceIdentity, at: URL(fileURLWithPath: record.sourcePath))
        try verifyBaseline("source", record: record, at: URL(fileURLWithPath: record.sourcePath))
    }

    private func verifyCandidate(_ record: AppTransferRecord, at url: URL) throws {
        guard let identity = record.candidateIdentity else { throw Self.failure("候选副本身份记录缺失。".localized, at: url) }
        try requireIdentity(identity, at: url)
        try verifyBaseline("candidate", record: record, at: url)
        try verifySignatures(record, root: url)
    }

    private func verifyExistingDestination(_ record: AppTransferRecord) throws {
        let destination = URL(fileURLWithPath: record.destinationPath)
        if let identity = record.existingDestinationIdentity {
            try requireIdentity(identity, at: destination)
            try verifyBaseline("existing", record: record, at: destination)
        } else if try AppTransferStore.exists(destination) {
            throw Self.failure("目标位置出现了其他对象，未覆盖。".localized, at: destination)
        }
    }

    private func ensureStage(_ journal: Journal, portal: Bool) throws {
        let path = portal ? journal.record.portalStagePath! : journal.record.stagePath
        let url = URL(fileURLWithPath: path)
        let identity = portal ? journal.record.portalStageIdentity : journal.record.stageIdentity
        if try AppTransferStore.exists(url) {
            guard let identity else { throw Self.failure("暂存目录创建后未完成归属记账，可以取消此尝试并保留该目录。".localized, at: url) }
            try requireIdentity(identity, at: url)
            return
        }
        guard identity == nil else { throw Self.failure("已登记的暂存目录不在原位置。".localized, at: url) }
        try requireParents(journal.record)
        guard mkdir(url.path, 0o700) == 0 else { throw Self.posix(url) }
        try checkpoint(.stageCreated, journal)
        let created = try DataPathIdentity.capture(url)
        if portal { journal.record.portalStageIdentity = created } else { journal.record.stageIdentity = created }
        try journal.save()
        try DurableFileIO.syncDirectory(at: url.deletingLastPathComponent())
    }

    private func cancelOwnedCandidate(_ journal: Journal) throws {
        let url = journal.record.candidateURL
        guard try AppTransferStore.exists(url) else { return }
        guard let identity = journal.record.candidateIdentity else {
            throw Self.failure("候选对象创建后未完成归属记账，已保留，可取消本次尝试。".localized, at: url)
        }
        try requireIdentity(journal.record.stageIdentity!, at: url.deletingLastPathComponent())
        try requireIdentity(identity, at: url)
        try removeFreshOwned(url)
        journal.record.candidateIdentity = nil
        journal.record.hasCandidateBaseline = false
        try journal.save()
    }

    private func removeFreshOwned(_ url: URL) throws {
        let baseline = try captureBaseline(url)
        let identity = try DataPathIdentity.capture(url)
        try remove(baseline, at: url, identity: identity, removalID: UUID(), partial: false)
        try DurableFileIO.syncDirectory(at: url.deletingLastPathComponent())
    }

    private func removeEmptyStage(_ url: URL, identity: DataPathIdentity?, parentIdentity: DataPathIdentity,
                                  journal: Journal) throws {
        let parent = url.deletingLastPathComponent()
        try requireIdentity(parentIdentity, at: parent)
        if try AppTransferStore.exists(url) {
            guard let identity else {
                if !journal.record.unclaimedPaths.contains(url.path) { journal.record.unclaimedPaths.append(url.path) }
                return
            }
            try requireIdentity(identity, at: url)
            guard try fileManager.contentsOfDirectory(atPath: url.path).isEmpty else {
                if !journal.record.unclaimedPaths.contains(url.path) { journal.record.unclaimedPaths.append(url.path) }
                return
            }
            try store.recheckWriterAdmission()
            guard rmdir(url.path) == 0 else { throw Self.posix(url) }
        }
        // A prior rmdir may have succeeded before its parent sync failed. The
        // same identity-bound barrier is owed on a cold retry of that absence.
        try requireIdentity(parentIdentity, at: parent)
        try hooks.synchronizeStagingParent(parent)
        try requireIdentity(parentIdentity, at: parent)
        try requireParents(journal.record)
        guard try !AppTransferStore.exists(url) else {
            throw Self.failure("暂存对象归属无法确认，已保留。".localized, at: url)
        }
        // Unknown contents were never deleted here. Once the user has removed
        // them and the owned empty directory is gone, its warning can finish.
        journal.record.unclaimedPaths.removeAll { $0 == url.path }
    }

    private func syncStageIfPresent(_ url: URL, identity: DataPathIdentity?, record: AppTransferRecord) throws {
        if try AppTransferStore.exists(url) {
            guard let identity else { throw Self.failure("暂存目录归属记录缺失。".localized, at: url) }
            try requireIdentity(identity, at: url)
            try DurableFileIO.syncDirectory(at: url)
        } else if record.phase != .committed || !record.cleanupItems.allSatisfy(\.completed) {
            throw Self.failure("暂存目录不在记录位置，已暂停清理。".localized, at: url)
        }
    }

    private func reconcileCancelled(_ journal: Journal) throws -> AppTransferResult {
        try requireParents(journal.record)
        journal.record.unclaimedPaths = try journal.record.unclaimedPaths.filter { try AppTransferStore.exists(URL(fileURLWithPath: $0)) }
        try journal.save()
        let value = result(journal.record)
        if journal.record.unclaimedPaths.isEmpty { try store.remove(journal.record.operationID) }
        return value
    }

    private func captureBaseline(_ url: URL) throws -> AppTransferBaseline {
        if try SignatureSnapshot.info(at: url).st_mode & S_IFMT == S_IFLNK {
            return .init(tree: nil, linkTarget: try fileManager.destinationOfSymbolicLink(atPath: url.path), linkIdentity: try DataPathIdentity.capture(url))
        }
        return .init(tree: try TreeCopySession.snapshot(at: url, profile: Self.copyProfile),
                     linkTarget: nil, linkIdentity: nil,
                     volumeUUID: try DataPathIdentity.capture(url).volumeUUID)
    }

    private func verifyBaseline(_ name: String, record: AppTransferRecord, at url: URL) throws {
        try verify(store.baseline(name, operationID: record.operationID), at: url, unchanged: true)
    }

    private func verify(_ baseline: AppTransferBaseline, at url: URL, unchanged: Bool) throws {
        if let tree = baseline.tree {
            if unchanged, let uuid = baseline.volumeUUID {
                try TreeCopySession.verifyUnchanged(at: url, against: tree, expectedVolumeUUID: uuid,
                                                    profile: Self.copyProfile)
            } else if unchanged {
                try TreeCopySession.verifyUnchanged(at: url, against: tree, profile: Self.copyProfile)
            } else {
                try TreeCopySession.verifyCopy(at: url, against: tree, profile: Self.copyProfile)
            }
        } else {
            guard let identity = baseline.linkIdentity, let target = baseline.linkTarget else { throw CocoaError(.fileReadCorruptFile) }
            try requireIdentity(identity, at: url)
            guard try fileManager.destinationOfSymbolicLink(atPath: url.path) == target else { throw Self.failure("链接内容已改变，未清理。".localized, at: url) }
        }
    }

    private func remove(_ baseline: AppTransferBaseline, at url: URL, identity: DataPathIdentity, removalID: UUID, partial: Bool) throws {
        try store.recheckWriterAdmission()
        if let tree = baseline.tree {
            try TreeCopySession.removeVerifiedCopy(at: url, against: tree, allowPartialRemoval: partial,
                                                   expectedVolumeUUID: identity.volumeUUID, removalID: removalID,
                                                   profile: Self.copyProfile)
        } else {
            let remaining = try TreeCopySession.retainedRemovalURL(at: url, removalID: removalID) ?? url
            try verify(baseline, at: remaining, unchanged: true)
            let quarantine = url.deletingLastPathComponent().appendingPathComponent(".appports-deleting-" + removalID.uuidString)
            if remaining != quarantine { try Self.moveExclusively(remaining, quarantine) }
            try requireIdentity(identity, at: quarantine)
            try verify(baseline, at: quarantine, unchanged: true)
            guard unlink(quarantine.path) == 0 else { throw Self.posix(quarantine) }
        }
    }

    private func requireIdentity(_ expected: DataPathIdentity, at url: URL) throws {
        guard try expected.matchesFilesystemObject(DataPathIdentity.capture(url)) else {
            throw Self.failure("路径对应的对象或磁盘已改变，已保留内容。".localized, at: url)
        }
    }

    private func requireNotRunning(source: URL, applicationPaths: [String]) throws {
        let snapshot = runningApplications()
        let urls = applicationPaths.map { $0.isEmpty ? source : source.appendingPathComponent($0) }
        if snapshot.contains(where: { app in app.bundleURL.map { Self.contains(source, Self.canonical($0)) } == true })
            || urls.contains(where: { AppRunningState.isRunning(appURL: $0, applications: snapshot) }) {
            throw AppMoverError.appIsRunning
        }
    }

    private func requireOldCopyNotRunning(_ item: AppTransferCleanupItem, record: AppTransferRecord) throws {
        let current = URL(fileURLWithPath: item.path)
        let original = URL(fileURLWithPath: item.originalPath)
        for app in runningApplications() {
            if let url = app.bundleURL {
                let path = Self.canonical(url)
                if Self.contains(current, path) || Self.contains(original, path) {
                    throw Self.failure("旧位置的应用仍在运行，应用位置已切换，退出后可继续清理。".localized, at: current)
                }
            } else if record.applicationPaths.contains(where: { relative in
                let url = relative.isEmpty ? current : current.appendingPathComponent(relative)
                return AppRunningState.isRunning(appURL: url, applications: [app])
            }) { throw AppMoverError.appIsRunning }
        }
    }

    private func applicationPaths(in root: URL, folder: Bool) throws -> [String] {
        if !folder { return [""] }
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
            .map(\.lastPathComponent).sorted()
    }

    private func signatureIsValid(at url: URL) throws -> Bool {
        var code: SecStaticCode?
        let creation = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        if creation == errSecCSUnsigned || creation == errSecCSBadObjectFormat { return false }
        guard creation == errSecSuccess, let code else {
            throw Self.failure("无法读取应用签名状态，未切换应用。".localized, at: url)
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    private func verifySignatures(_ record: AppTransferRecord, root: URL) throws {
        for (relative, wasValid) in record.signatureChecks where wasValid {
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            guard try signatureIsValid(at: url) else { throw Self.failure("目标应用未通过原有签名校验，原件已保留。".localized, at: url) }
        }
    }

    private func withoutQuarantine(_ snapshot: TreeCopySnapshot) -> TreeCopySnapshot {
        TreeCopySnapshot(restoredRootOwnership: snapshot.restoredRootOwnership, ownershipCompatibility: snapshot.ownershipCompatibility,
            entries: snapshot.entries.map { item in
                .init(path: item.path, kind: item.kind, identity: item.identity, mode: item.mode, uid: item.uid, gid: item.gid,
                    flags: item.flags, birthTime: item.birthTime, modificationTime: item.modificationTime,
                    extendedAttributes: item.extendedAttributes.filter { $0.key != "com.apple.quarantine" }, resourceFork: item.resourceFork, acl: item.acl,
                    size: item.size, digest: item.digest, linkTarget: item.linkTarget, hardlinkGroup: item.hardlinkGroup)
            }, excludedRootEntries: snapshot.excludedRootEntries)
    }

    private func handle(_ error: Error, journal: Journal) throws -> AppTransferResult {
        journal.record.recoverableReason = error.localizedDescription
        if journal.record.isSwitchComplete || (try? observeActivation(journal.record)) == true {
            if journal.record.committedAt == nil { journal.record.committedAt = Date() }
            if journal.record.phase != .committed { journal.record.phase = .switching }
            try? journal.save()
            return result(journal.record, warnings: [error.localizedDescription],
                extraTasks: journal.record.pendingTasks.isEmpty ? [.init(kind: .recordCommit, path: journal.record.activeDestinationPath,
                    message: "应用位置已切换，收尾待重试。".localized)] : [])
        }
        try? journal.save()
        throw error
    }

    private func result(_ record: AppTransferRecord, warnings: [String] = [], extraTasks: [AppTransferPendingTask] = []) -> AppTransferResult {
        let pending = record.pendingTasks + extraTasks
        let sourceRemains: Bool
        if record.direction == .restore {
            sourceRemains = (try? AppTransferStore.exists(URL(fileURLWithPath: record.sourcePath))) ?? true
        } else { sourceRemains = record.cleanupItems.contains { $0.role == .source && !$0.completed } }
        return .init(operationID: record.operationID, direction: record.direction,
            destinationURL: URL(fileURLWithPath: record.activeDestinationPath), isSwitchComplete: record.isSwitchComplete,
            pendingTasks: pending, warnings: Array(Set(warnings + pending.map(\.message))).sorted(),
            retiredLocalPortalURLs: record.legacyPortals.filter(\.retired).map { URL(fileURLWithPath: $0.path) },
            externalSourceRemains: sourceRemains)
    }

    private func checkpoint(_ point: AppTransferHooks.Checkpoint, _ journal: Journal) throws { try hooks.checkpoint?(point, journal.record) }
    static func failure(_ message: String, at url: URL) -> NSError {
        NSError(domain: "AppPorts.AppTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message + "\n" + url.path, NSFilePathErrorKey: url.path])
    }
    private static func posix(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    private static func canonical(_ url: URL) -> URL { url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL }
    private static func contains(_ root: URL, _ path: URL) -> Bool { path.path == root.path || path.path.hasPrefix(root.path + "/") }
    /// Atomic swap of two existing names.
    ///
    /// `RENAME_SWAP` is unsupported on some filesystems (ExFAT, FAT). There is no
    /// atomic replacement there, so the fallback stages one name aside and moves
    /// the other into place. The window is real but tiny, and it only opens on a
    /// filesystem that cannot express the atomic operation at all — refusing
    /// outright would make that drive unusable for migration.
    private static func exchange(_ a: URL, _ b: URL) throws {
        if renameatx_np(AT_FDCWD, a.path, AT_FDCWD, b.path, UInt32(RENAME_SWAP)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: a.path])
        }
        let staged = a.deletingLastPathComponent()
            .appendingPathComponent(".appports-swap-" + UUID().uuidString)
        try moveExclusively(a, staged)
        do {
            try moveExclusively(b, a)
        } catch {
            try? moveExclusively(staged, a)
            throw error
        }
        do {
            try moveExclusively(staged, b)
        } catch {
            try? moveExclusively(a, b)
            try? moveExclusively(staged, a)
            throw error
        }
    }

    /// Rename that never replaces an existing name.
    ///
    /// `RENAME_EXCL` is unsupported on some filesystems (ExFAT, FAT). The fallback
    /// re-checks the target immediately before a plain `rename`, which keeps the
    /// "do not overwrite" contract even though the check and the rename are not a
    /// single atomic operation.
    private static func moveExclusively(_ source: URL, _ target: URL) throws {
        if renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: target.path])
        }
        var info = stat()
        guard lstat(target.path, &info) != 0, errno == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: [NSFilePathErrorKey: target.path])
        }
        guard rename(source.path, target.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: target.path])
        }
    }
    private final class Journal: @unchecked Sendable {
        var record: AppTransferRecord
        let store: AppTransferStore
        init(_ record: AppTransferRecord, store: AppTransferStore) { self.record = record; self.store = store }
        func save() throws { try store.save(record) }
    }
}
