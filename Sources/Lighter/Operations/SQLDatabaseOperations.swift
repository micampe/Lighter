//
//  Created by Helge Heß.
//  Copyright © 2022 ZeeZide GmbH.
//

/**
 * A protocol that can be implemented by objects that allow for database
 * operations. I.e. ``SQLDatabase`` and ``SQLTransaction``.
 *
 * The actual operations can be found in:
 * - ``SQLDatabaseFetchOperations``
 * - ``SQLDatabaseChangeOperations``
 * and async/await versions in:
 * - ``SQLDatabaseFetchOperations``
 * - ``SQLDatabaseAsyncChangeOperations``
 */
public protocol SQLDatabaseOperations {
  
  associatedtype RecordTypes
  
  static var recordTypes : RecordTypes { get }
  
  var connectionHandler : SQLConnectionHandler { get }
}


import SQLite3

// MARK: - Raw SQL Fetches

public extension SQLDatabaseOperations {

  /**
   * Performs a raw SQL fetch operation, optionally taking an array of bindings.
   *
   * The function will call the yield callback with the SQLite statement handle
   * (and a parameter to stop execution).
   *
   * - Parameters:
   *   - sql:      The SQL to execute.
   *   - bindings: Optional set of bindings (`?` in the SQL).
   *   - readOnly: Whether the connection should be opened read/only.
   *   - yield:    A closure that is called for each result record.
   *               The first argument is the SQLite prepared statement handle,
   *               the second a bool that can be used to stop the fetch.
   */
  func fetch(_ sql: String, _ bindings: [ SQLiteValueType ]? = nil,
             readOnly: Bool = true,
             yield: ( OpaquePointer, inout Bool ) throws -> Void) throws
  {
    try connectionHandler.withConnection(readOnly: readOnly) { db in
      var maybeStmt : OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &maybeStmt, nil) == SQLITE_OK,
            let stmt = maybeStmt else
      {
        assertionFailure("Failed to prepare SQL \(sql)")
        throw SQLError(db)
      }
      defer { sqlite3_finalize(stmt) }

      // Idea to workaround nesting issue by @DeFrenZ, thanks!
      // https://sveinhal.github.io/2018/07/02/without-actually-escaping/
      var stopError : Swift.Error?
      withoutActuallyEscaping(yield) { yield in
        bind_values(stmt, bindings) {
          repeat {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            else if rc != SQLITE_ROW {
              stopError = SQLError(db)
              break
            }
            
            var stop = false
            do {
              try yield(stmt, &stop)
            }
            catch {
              stopError = error
              break
            }
            if stop { break }
          }
          while true
        }
      }
      
      if let error = stopError { throw error }
    }
  }
}

public extension SQLDatabaseOperations {
    
  /**
   * Performs a raw SQL operation, dropping result values.
   *
   * - Parameters:
   *   - sql:      The SQL to execute.
   *   - readOnly: Whether the connection should be opened read/only.
   *   - bindings: Optional bind variables.
   */
  @inlinable
  func execute(_ sql: String, _ bindings: [ SQLiteValueType ]? = nil,
               readOnly: Bool = false) throws
  {
    try fetch(sql, bindings, readOnly: readOnly) { _, stop in stop = true }
  }
}

/// Binds all `values`, then runs `content` once with the statement fully bound.
///
/// Every `SQLiteValueType.bind` must let SQLite copy the value (`SQLITE_TRANSIENT`
/// for text and blobs) rather than lend it a buffer that only lives for the
/// duration of the `then:` closure. Lending would require nesting a scope per
/// value, which recurses once per bind parameter and overflows the stack on
/// large `IN (…)` lists — cooperative threads have a 512K stack and died at ~276.
fileprivate func bind_values<C>(_              stmt : OpaquePointer?,
                                _            values : C?,
                                startingAtIndex idx : Int32 = 1,
                                content             : () -> Void)
              where C: Collection, C.Element == SQLiteValueType
{
  guard let stmt = stmt else {
    assertionFailure("Missing statement for bind.")
    return content()
  }
  guard let values = values else { return content() }

  for ( offset, value ) in values.enumerated() {
    value.bind(unsafeSQLite3StatementHandle: stmt, index: idx + Int32(offset)) {}
  }
  content()
}
