//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension MessageBackup {
    public struct InteractionUniqueId: MessageBackupLoggableId, Hashable {
        let value: String

        public init(interaction: TSInteraction) {
            self.value = interaction.uniqueId
        }

        // MARK: MessageBackupLoggableId

        public var typeLogString: String { "TSInteraction" }
        public var idLogString: String { value }
    }

    internal struct InteractionArchiveDetails {
        typealias DirectionalDetails = BackupProto.ChatItem.DirectionalDetails
        typealias ChatItemType = BackupProto.ChatItem.Item

        let author: RecipientId
        let directionalDetails: DirectionalDetails
        let expireStartDate: UInt64?
        let expiresInMs: UInt64?
        // TODO: edit revisions
        let revisions: [BackupProto.ChatItem] = []
        // TODO: sms
        let isSms: Bool = false
        let isSealedSender: Bool
        let chatItemType: ChatItemType
    }

    enum SkippableChatUpdate {
        enum SkippableGroupUpdate {
            /// This is a group update from back when we kept raw strings on
            /// disk, instead of metadata required to construct the string. We
            /// knowingly drop these.
            case legacyRawString

            /// In backups, we collapse the `inviteFriendsToNewlyCreatedGroup`
            /// into the `createdByLocalUser`; the former is just omitted from
            /// backups.
            case inviteFriendsToNewlyCreatedGroup
        }

        /// Represents types of ``TSErrorMessage``s (as described by
        /// ``TSErrorMessageType``) that are legacy and exclued from backups.
        enum LegacyErrorMessageType {
            /// See: `TSErrorMessageType/noSession`
            case noSession
            /// See: `TSErrorMessageType/wrongTrustedIdentityKey`
            case wrongTrustedIdentityKey
            /// See: `TSErrorMessageType/invalidKeyException`
            case invalidKeyException
            /// See: `TSErrorMessageType/missingKeyId`
            case missingKeyId
            /// See: `TSErrorMessageType/invalidMessage`
            case invalidMessage
            /// See: `TSErrorMessageType/duplicateMessage`
            case duplicateMessage
            /// See: `TSErrorMessageType/invalidVersion`
            case invalidVersion
            /// See: `TSErrorMessageType/unknownContactBlockOffer`
            case unknownContactBlockOffer
            /// See: `TSErrorMessageType/groupCreationFailed`
            case groupCreationFailed
        }

        enum LegacyInfoMessageType {
            /// See: `TSInfoMessageType/userNotRegistered`
            case userNotRegistered
            /// See: `TSInfoMessageType/typeUnsupportedMessage`
            case typeUnsupportedMessage
            /// See: `TSInfoMessageType/typeGroupQuit`
            case typeGroupQuit
            /// See: `TSInfoMessageType/addToContactsOffer`
            case addToContactsOffer
            /// See: `TSInfoMessageType/addUserToProfileWhitelistOffer`
            case addUserToProfileWhitelistOffer
            /// See: `TSInfoMessageType/addGroupToProfileWhitelistOffer`
            case addGroupToProfileWhitelistOffer
            /// See: `TSInfoMessageType/syncedThread`
            case syncedThread
        }

        /// Some group updates are deliberately skipped.
        case skippableGroupUpdate(SkippableGroupUpdate)

        /// This is a legacy ``TSErrorMessage`` that we no longer support, and
        /// is correspondingly dropped when creating a backup.
        case legacyErrorMessage(LegacyErrorMessageType)

        /// This is a legacy ``TSInfoMessage`` that we no longer support, and
        /// is correspondingly dropped when creating a backup.
        case legacyInfoMessage(LegacyInfoMessageType)

        /// This is a ``TSInfoMessage`` telling us about a contact being hidden,
        /// which doesn't go into the backup. Instead, we track and handle info
        /// messages for recipient hidden state separately.
        case contactHiddenInfoMessage
    }

    internal enum ArchiveInteractionResult<Component> {
        case success(Component)

        // MARK: Skips

        /// This is a past revision that was since edited; can be safely skipped, as its
        /// contents will be represented in the latest revision.
        case isPastRevision

        /// We intentionally skip archiving some chat-update interactions.
        case skippableChatUpdate(SkippableChatUpdate)

        // TODO: remove this once we flesh out implementation for all interactions.
        case notYetImplemented

        // MARK: Errors

        /// Some portion of the interaction failed to archive, but we can still archive the rest of it.
        /// e.g. some recipient details are missing, so we archive without that recipient.
        case partialFailure(Component, [ArchiveFrameError<InteractionUniqueId>])
        /// The entire message failed and should be skipped.
        /// Other messages are unaffected.
        case messageFailure([ArchiveFrameError<InteractionUniqueId>])
        /// Catastrophic failure, which should stop _all_ message archiving.
        case completeFailure(FatalArchivingError)
    }

    internal enum RestoreInteractionResult<Component> {
        case success(Component)
        /// Some portion of the interaction failed to restore, but we can still restore the rest of it.
        /// e.g. a reaction failed to parse, so we just drop that reaction.
        case partialRestore(Component, [RestoreFrameError<ChatItemId>])
        /// The entire message failed and should be skipped.
        /// Other messages are unaffected.
        case messageFailure([RestoreFrameError<ChatItemId>])
    }
}

internal protocol MessageBackupInteractionArchiver: MessageBackupProtoArchiver {

    typealias Details = MessageBackup.InteractionArchiveDetails

    static var archiverType: MessageBackup.ChatItemArchiverType { get }

    func archiveInteraction(
        _ interaction: TSInteraction,
        context: MessageBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<Details>

    func restoreChatItem(
        _ chatItem: BackupProto.ChatItem,
        chatThread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> MessageBackup.RestoreInteractionResult<Void>
}

extension MessageBackup.ArchiveInteractionResult {

    enum BubbleUp<T, E> {
        case `continue`(T)
        case bubbleUpError(MessageBackup.ArchiveInteractionResult<E>)
    }

    /// Make it easier to "bubble up" an error case of ``ArchiveInteractionResult`` thrown deeper in the call stack.
    /// Basically, collapses all the cases that should just be bubbled up to the caller (error cases) into an easily returnable case,
    /// ditto for the success or partial success cases, and handles updating partialErrors along the way.
    ///
    /// Concretely, turns this:
    ///
    /// switch someResult {
    /// case .success(let value):
    ///   myVar = value
    /// case .partialFailure(let value, let errors):
    ///   myVar = value
    ///   partialErrors.append(contentsOf: errors)
    /// case someFailureCase(let someErrorOrErrors)
    ///   let coalescedErrorOrErrors = partialErrors.coalesceSomehow(with: someErrorOrErrors)
    ///   // Just bubble up the error after coalescing
    ///   return .someFailureCase(coalescedErrorOrErrors)
    /// // ...
    /// // The same for every other error case that should be bubbled up
    /// // ...
    /// }
    ///
    /// Into this:
    ///
    /// switch someResult.bubbleUp(&partialErrors) {
    /// case .success(let value):
    ///   myVar = value
    /// case .bubbleUpError(let error):
    ///   return error
    /// }
    func bubbleUp<ErrorResultType>(
        _ resultType: ErrorResultType.Type = ErrorResultType.self,
        partialErrors: inout [MessageBackup.ArchiveFrameError<MessageBackup.InteractionUniqueId>]
    ) -> BubbleUp<Component, ErrorResultType> {
        switch self {
        case .success(let value):
            return .continue(value)

        case .partialFailure(let value, let errors):
            // Continue through partial failures.
            partialErrors.append(contentsOf: errors)
            return .continue(value)

        // These types are just bubbled up as-is
        case .isPastRevision:
            return .bubbleUpError(.isPastRevision)
        case .skippableChatUpdate(let skippableChatUpdate):
            return .bubbleUpError(.skippableChatUpdate(skippableChatUpdate))
        case .notYetImplemented:
            return .bubbleUpError(.notYetImplemented)
        case .completeFailure(let error):
            return .bubbleUpError(.completeFailure(error))

        case .messageFailure(let errors):
            // Add message failure to partial errors and bubble it up.
            partialErrors.append(contentsOf: errors)
            return .bubbleUpError(.messageFailure(partialErrors))
        }
    }
}

extension MessageBackup.RestoreInteractionResult {

    /// Returns nil for ``RestoreInteractionResult.messageFailure``, otherwise
    /// returns the restored component. Regardless, accumulates any errors so that the caller
    /// can return the passed in ``partialErrors`` array in the final result.
    ///
    /// Concretely, turns this:
    ///
    /// switch someResult {
    /// case .success(let value):
    ///   myVar = value
    /// case .partialRestore(let value, let errors):
    ///   myVar = value
    ///   partialErrors.append(contentsOf: errors)
    /// case messageFailure(let errors)
    ///   partialErrors.append(contentsOf: errors)
    ///   return .messageFailure(partialErrors)
    /// }
    ///
    /// Into this:
    ///
    /// guard let myVar = someResult.unwrap(&partialErrors) else {
    ///   return .messageFailure(partialErrors)
    /// }
    func unwrap(
        partialErrors: inout [MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>]
    ) -> Component? {
        switch self {
        case .success(let component):
            return component
        case .partialRestore(let component, let errors):
            partialErrors.append(contentsOf: errors)
            return component
        case .messageFailure(let errors):
            partialErrors.append(contentsOf: errors)
            return nil
        }
    }
}

extension MessageBackup.RestoreInteractionResult where Component == Void {

    /// Returns false for ``RestoreInteractionResult.messageFailure``, otherwise
    /// returns true. Regardless, accumulates any errors so that the caller
    /// can return the passed in ``partialErrors`` array in the final result.
    func unwrap(
        partialErrors: inout [MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>]
    ) -> Bool {
        switch self {
        case .success:
            return true
        case .partialRestore(_, let errors):
            partialErrors.append(contentsOf: errors)
            return true
        case .messageFailure(let errors):
            partialErrors.append(contentsOf: errors)
            return false
        }
    }
}

extension BackupProto.ChatItem {

    var id: MessageBackup.ChatItemId {
        return .init(backupProtoChatItem: self)
    }
}

extension TSInteraction {

    var uniqueInteractionId: MessageBackup.InteractionUniqueId {
        return .init(interaction: self)
    }

    var chatItemId: MessageBackup.ChatItemId {
        return .init(interaction: self)
    }
}
