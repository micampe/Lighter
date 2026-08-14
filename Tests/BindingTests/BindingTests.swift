//
//  Created by Helge Heß.
//  Copyright © 2022 ZeeZide GmbH.
//

import XCTest
import SQLite3
import Foundation
@testable import Lighter

/// `bind_values` binds one parameter per iteration. It used to recurse instead,
/// nesting a `withCString` scope per value so the borrowed buffers stayed alive,
/// which overflowed the stack on large `IN (…)` lists — a cooperative thread has
/// a 512K stack and died at ~276 parameters.
final class BindingTests: XCTestCase {

  private struct TestDatabase: SQLDatabaseOperations {
    static let recordTypes = ()
    let connectionHandler : SQLConnectionHandler
  }

  private func makeDatabase(_ handle: OpaquePointer) -> TestDatabase {
    TestDatabase(connectionHandler: .unsafeReuse(
      handle, url: URL(fileURLWithPath: "/tmp/bindingtests.db")
    ))
  }

  /// Selects one row out of a 5,000 parameter `IN (…)`, on the cooperative pool
  /// so the small stack is the one under test.
  func testBindsManyParametersWithoutOverflowingTheStack() async throws {
    var maybeHandle : OpaquePointer?
    XCTAssertEqual(sqlite3_open(":memory:", &maybeHandle), SQLITE_OK)
    guard let handle = maybeHandle else { return XCTFail("no database handle") }
    defer { sqlite3_close(handle) }

    XCTAssertEqual(
      sqlite3_exec(handle, "CREATE TABLE keys ( key TEXT )", nil, nil, nil),
      SQLITE_OK
    )
    XCTAssertEqual(
      sqlite3_exec(handle, "INSERT INTO keys VALUES ( 'key-4321' )", nil, nil, nil),
      SQLITE_OK
    )

    let db     = makeDatabase(handle)
    let keys   = (0..<5000).map { "key-\($0)" }
    let params = Array(repeating: "?", count: keys.count).joined(separator: ", ")
    let sql    = "SELECT key FROM keys WHERE key IN ( \(params) )"

    let matches = try await Task {
      var matches = [ String ]()
      try db.fetch(sql, keys) { stmt, _ in
        matches.append(try String(unsafeSQLite3StatementHandle: stmt, column: 0))
      }
      return matches
    }.value

    XCTAssertEqual(matches, [ "key-4321" ])
  }

  /// The values must survive the bind: with `SQLITE_TRANSIENT` SQLite copies
  /// them, so nothing depends on a buffer that dies when `bind` returns.
  func testBoundValuesSurviveTheBindingScope() throws {
    var maybeHandle : OpaquePointer?
    XCTAssertEqual(sqlite3_open(":memory:", &maybeHandle), SQLITE_OK)
    guard let handle = maybeHandle else { return XCTFail("no database handle") }
    defer { sqlite3_close(handle) }

    let db = makeDatabase(handle)

    // Mixed types, all bound before the statement is stepped. Texts and blobs
    // are the interesting ones: they used to lend SQLite a buffer scoped to the
    // `bind` call.
    let text  = "hello \u{1F600} wörld"
    let url   = URL(string: "https://example.com/a?b=c")!
    let data  = Data((0..<512).map { UInt8($0 % 251) })
    let bytes = [ UInt8 ]([ 0, 1, 2, 250, 255 ])

    var texts = [ String ]()
    var blobs = [ Data ]()
    try db.fetch("SELECT ?, ?, ?, ?, ?, ?",
                 [ text, text[...], url, 42, data, bytes ]) { stmt, _ in
      for column in Int32(0)..<4 {
        texts.append(try String(unsafeSQLite3StatementHandle: stmt, column: column))
      }
      blobs.append(try Data(unsafeSQLite3StatementHandle: stmt, column: 4))
      blobs.append(try Data(unsafeSQLite3StatementHandle: stmt, column: 5))
    }

    XCTAssertEqual(texts, [ text, text, url.absoluteString, "42" ])
    XCTAssertEqual(blobs, [ data, Data(bytes) ])
  }
}
