import Foundation
import SQLite3

/// Read-only access to the main app's databases in the shared App Group
/// container. The NSE only ever reads; the main app owns all writes, which
/// keeps SQLite locking simple.
enum NSEStore {
    static let appGroupID = "group.me.anemoneya.gecko"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var dataDir: URL? {
        container?.appendingPathComponent("xdg-data/dino")
    }

    /// First account's bare JID — a cheap proof that the shared dino.db opens.
    static func accountJid() -> String? {
        guard let db = dataDir?.appendingPathComponent("dino.db").path else {
            NSLog("NSEStore: no App Group container")
            return nil
        }
        guard FileManager.default.fileExists(atPath: db) else {
            NSLog("NSEStore: db missing at %@", db)
            return nil
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(db, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            NSLog("NSEStore: open failed: %s", sqlite3_errmsg(handle))
            return nil
        }
        defer { sqlite3_close(handle) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT bare_jid FROM account LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            NSLog("NSEStore: prepare failed: %s", sqlite3_errmsg(handle))
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
            let jid = String(cString: text)
            NSLog("NSEStore: account jid = %@", jid)
            return jid
        }
        NSLog("NSEStore: no account row")
        return nil
    }
}
