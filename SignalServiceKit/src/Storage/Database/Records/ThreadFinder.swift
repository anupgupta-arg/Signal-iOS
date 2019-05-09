//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDBCipher

public protocol ThreadFinder {
    associatedtype ReadTransaction

    func threadCount(isArchived: Bool, transaction: ReadTransaction) throws -> UInt
    func enumerateThreads(isArchived: Bool, transaction: ReadTransaction, block: @escaping (TSThread) -> Void) throws
}

public class AnyThreadFinder: ThreadFinder {
    public typealias ReadTransaction = SDSAnyReadTransaction

    let grdbAdapter: GRDBThreadFinder = GRDBThreadFinder()
    let yapAdapter: YAPDBThreadFinder = YAPDBThreadFinder()

    public init() { }

    public func threadCount(isArchived: Bool, transaction: SDSAnyReadTransaction) throws -> UInt {
        switch transaction.readTransaction {
        case .grdbRead(let grdb):
            return try grdbAdapter.threadCount(isArchived: isArchived, transaction: grdb.database)
        case .yapRead(let yap):
            return yapAdapter.threadCount(isArchived: isArchived, transaction: yap)
        }
    }

    public func enumerateThreads(isArchived: Bool, transaction: SDSAnyReadTransaction, block: @escaping (TSThread) -> Void) throws {
        switch transaction.readTransaction {
        case .grdbRead(let grdb):
            try grdbAdapter.enumerateThreads(isArchived: isArchived, transaction: grdb.database, block: block)
        case .yapRead(let yap):
            yapAdapter.enumerateThreads(isArchived: isArchived, transaction: yap, block: block)
        }
    }
}

struct YAPDBThreadFinder: ThreadFinder {
    typealias ReadTransaction = YapDatabaseReadTransaction

    func threadCount(isArchived: Bool, transaction: YapDatabaseReadTransaction) -> UInt {
        return ext(transaction).numberOfItems(inGroup: group(isArchived: isArchived))
    }

    func enumerateThreads(isArchived: Bool, transaction: YapDatabaseReadTransaction, block: @escaping (TSThread) -> Void) {
        ext(transaction).enumerateKeysAndObjects(inGroup: group(isArchived: isArchived),
                                                 with: NSEnumerationOptions.reverse) { _, _, object, _, _ in
                                                    guard let thread = object as? TSThread else {
                                                        owsFailDebug("unexpected object: \(type(of: object))")
                                                        return
                                                    }
                                                    block(thread)
        }
    }

    // MARK: -

    private static let extensionName: String = TSThreadDatabaseViewExtensionName

    private func group(isArchived: Bool) -> String {
        return isArchived ? TSArchiveGroup : TSInboxGroup
    }

    private func ext(_ transaction: YapDatabaseReadTransaction) -> YapDatabaseViewTransaction {
        return transaction.ext(type(of: self).extensionName) as! YapDatabaseViewTransaction
    }
}

struct GRDBThreadFinder: ThreadFinder {
    typealias ReadTransaction = Database

    static let cn = TSThreadRecord.columnName

    func threadCount(isArchived: Bool, transaction: Database) throws -> UInt {
        guard let count = try UInt.fetchOne(transaction, sql: """
            SELECT COUNT(*)
            FROM (
                SELECT
                    CASE maxInteractionId <= \(columnForThread: .archivedAsOfMessageSortId)
                        WHEN 1 THEN 1
                        ELSE 0
                    END isArchived
                FROM \(TSThreadRecord.databaseTableName)
                LEFT JOIN (
                    SELECT
                        MAX(\(columnForInteraction: .id)) as maxInteractionId,
                        \(columnForInteraction: .threadUniqueId)
                    FROM \(TSInteractionRecord.databaseTableName)
                    GROUP BY \(columnForInteraction: .threadUniqueId)
                ) latestInteractions
                ON latestInteractions.\(columnForInteraction: .threadUniqueId) = \(columnForThread: .uniqueId)
            )
            WHERE isArchived = ?
        """,
                                            arguments: [isArchived]) else {
                                                owsFailDebug("count was unexpectedly nil")
                                                return 0
        }

        return count
    }

    func enumerateThreads(isArchived: Bool, transaction: Database, block: @escaping (TSThread) -> Void) throws {
        try TSThreadRecord.fetchCursor(transaction, sql: """
            SELECT *
            FROM (
                SELECT
                    \(TSThreadRecord.databaseTableName).*,
                    CASE maxInteractionId <= \(columnForThread: .archivedAsOfMessageSortId)
                        WHEN 1 THEN 1
                        ELSE 0
                    END isArchived
                FROM \(TSThreadRecord.databaseTableName)
                LEFT JOIN (
                    SELECT
                        MAX(\(columnForInteraction: .id)) as maxInteractionId,
                        \(columnForInteraction: .threadUniqueId)
                    FROM \(TSInteractionRecord.databaseTableName)
                    GROUP BY \(columnForInteraction: .threadUniqueId)
                ) latestInteractions
                ON latestInteractions.\(columnForInteraction: .threadUniqueId) = \(columnForThread: .uniqueId)
                ORDER BY maxInteractionId DESC
            )
            WHERE isArchived = ?
        """,
                                     arguments: [isArchived]).forEach { threadRecord in
                                        block(try TSThread.fromRecord(threadRecord))
        }
    }
}
