//===--- IndexStoreDBTests.swift ------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import IndexStoreDB
import XCTest
import Foundation

struct TestLoc {
  var url: URL
  var line: Int
  var column: Int
}

func isSourceFileExtension(_ ext: String) -> Bool {
  switch ext {
    case "swift", "c", "cpp", "m", "mm", "h", "hpp":
      return true
    default:
      return false
  }
}

struct LocationScanner {

  var result: [String: TestLoc] = [:]

  enum Error: Swift.Error {
    case noSuchFileOrDirectory(URL)
    case nestedComment(TestLoc)
    case duplicateKey(String, TestLoc, TestLoc)
  }

  mutating func scan(_ str: String, url: URL) throws {
    if str.count < 4 {
      return
    }

    var last: Character = "X"
    var i = str.startIndex
    var bodyStart: String.Index? = nil
    var commentNestingLevel = 0
    var line = 1
    var column = 1

    while i != str.endIndex {
      let c = str[i]

      let x = 1/**/*/**/2

      switch (last, c) {
      case ("/", "*"):
        if commentNestingLevel > 0 {
          throw Error.nestedComment(TestLoc(url: url, line: line, column: column))
        }
        bodyStart = str.index(after: i)
        commentNestingLevel += 1
        column += 1
        i = str.index(after: i)
        last = "X" // /*/ is not a full comment
        continue
        
      case ("*", "/"):
        if commentNestingLevel == 1 {
          let name = String(str[bodyStart!..<str.index(before: i)])
          let loc =  TestLoc(url: url, line: line, column: column + 1)
          if let prevLoc = result[name] {
            throw Error.duplicateKey(name, prevLoc, loc)
          }
          result[name] = loc
          bodyStart = nil
        }
        last = c
        column += 1
        i = str.index(after: i)
        if commentNestingLevel > 0 {
          commentNestingLevel -= 1
          last = "X" // /**/* is only one comment
        }
        continue

      case (_, "\n"):
        line += 1
        column = 0

      default:
        break
      }

      last = c
      column += 1
      i = str.index(after: i)
    }
  }

  mutating func scan(file: URL) throws {
    let content = try String(contentsOfFile: file.path, encoding: .utf8)
    try scan(content, url: file)
  }

  mutating func scan(rootDirectory: URL) throws {
    let fm = FileManager.default

    guard let generator = fm.enumerator(at: rootDirectory, includingPropertiesForKeys: []) else {
      throw Error.noSuchFileOrDirectory(rootDirectory)
    }

    while let url = generator.nextObject() as? URL {
      if isSourceFileExtension(url.pathExtension) {
        try scan(file: url)
      }
    }
  }
}

func scanLocations(rootDirectory: URL) throws -> [String: TestLoc] {
  var scanner = LocationScanner()
  try scanner.scan(rootDirectory: rootDirectory)
  return scanner.result
}

final class TestProject {
  var sourceRoot: URL
  var locations: [String: TestLoc]

  init(sourceRoot: URL) throws {
    self.sourceRoot = sourceRoot
    self.locations = try scanLocations(rootDirectory: sourceRoot)
  }
}

final class LocationScannerTests: XCTestCase {

  static let magicURL: URL = URL(fileURLWithPath: "/magic.swift")

  struct Loc: Equatable, Comparable {
    var url: URL
    var name: String
    var line: Int
    var column: Int
    init(url: URL = LocationScannerTests.magicURL, _ name: String, _ line: Int, _ column: Int) {
      self.url = url
      self.name = name
      self.line = line
      self.column = column
    }
    init(_ name: String, _ loc: TestLoc) {
      self.url = loc.url
      self.name = name
      self.line = loc.line
      self.column = loc.column
    }
    static func <(a: Loc, b: Loc) -> Bool {
      return (a.url.absoluteString, a.line, a.column, a.name) <
             (b.url.absoluteString, b.line, b.column, b.name)
    }
  }

  func scanString(_ str: String) throws -> [Loc] {
    var scanner = LocationScanner()
    try scanner.scan(str, url: LocationScannerTests.magicURL)
    return scanner.result.map { key, value in Loc(key, value) }.sorted()
  }

  func scanDir(_ dir: URL) throws -> [Loc] {
    return try scanLocations(rootDirectory: dir).map { key, value in Loc(key, value) }.sorted()
  }

  func testSmall() throws {
    XCTAssertEqual(try scanString(""), [])
    XCTAssertEqual(try scanString("/"), [])
    XCTAssertEqual(try scanString("/*"), [])
    XCTAssertEqual(try scanString("/**"), [])
    XCTAssertEqual(try scanString("**/"), [])
    XCTAssertEqual(try scanString("/*/"), [])
    XCTAssertEqual(try scanString("/**/"), [Loc("", 1, 5)])
    XCTAssertEqual(try scanString("/*a*/*/*b*/"), [Loc("a", 1, 6), Loc("b", 1, 12)])
    XCTAssertEqual(try scanString("/**/ "), [Loc("", 1, 5)])
    XCTAssertEqual(try scanString(" /**/"), [Loc("", 1, 6)])
    XCTAssertEqual(try scanString("*/**/"), [Loc("", 1, 6)])
    XCTAssertEqual(try scanString(" /**/a"), [Loc("", 1, 6)])
  }

  func testName() throws {
    XCTAssertEqual(try scanString("/*a*/"), [Loc("a", 1, 6)])
    XCTAssertEqual(try scanString("/*abc*/"), [Loc("abc", 1, 8)])
    XCTAssertEqual(try scanString("/*a:b*/"), [Loc("a:b", 1, 8)])
  }

  func testDuplicate() throws {
    XCTAssertThrowsError(try scanString("/*a*//*a*/"))
    XCTAssertThrowsError(try scanString("/**//**/"))
  }

  func testNested() throws {
    XCTAssertThrowsError(try scanString("/*/**/*/"))
    XCTAssertThrowsError(try scanString("/* /**/*/"))
    XCTAssertThrowsError(try scanString("/*/**/ */"))
    XCTAssertThrowsError(try scanString("/*/* */*/"))
  }

  func testLocation() throws {
    XCTAssertEqual(try scanString("/*a*/"), [Loc("a", 1, 6)])
    XCTAssertEqual(try scanString("   /*a*/"), [Loc("a", 1, 9)])
    XCTAssertEqual(try scanString("""

      /*a*/
      """), [Loc("a", 2, 6)])
    XCTAssertEqual(try scanString("""


      /*a*/
      """), [Loc("a", 3, 6)])
    XCTAssertEqual(try scanString("""
      a
      b
      /*a*/
      """), [Loc("a", 3, 6)])
    XCTAssertEqual(try scanString("""
      a

      b /*a*/
      """), [Loc("a", 3, 8)])
    XCTAssertEqual(try scanString("""

      /*a*/

      """), [Loc("a", 2, 6)])
  }

  func testMultiple() throws {
    XCTAssertEqual(try scanString("""
      func /*f*/f() {
        /*g:call*/g(/*g:arg1*/1)
      }/*end*/
      """), [
        Loc("f", 1, 11),
        Loc("g:call", 2, 13),
        Loc("g:arg1", 2, 25),
        Loc("end", 3, 9),
    ])
  }

  func testDirectory() throws {
    let proj1 = URL(fileURLWithPath: #file)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("INPUTS")
      .appendingPathComponent("proj1")
    XCTAssertEqual(try scanDir(proj1), [
      Loc(url: proj1.appendingPathComponent("a.swift"), "a:def", 1, 15),
      Loc(url: proj1.appendingPathComponent("a.swift"), "b:call", 2, 13),
      Loc(url: proj1.appendingPathComponent("a.swift"), "c:call", 3, 13),
      Loc(url: proj1.appendingPathComponent("b.swift"), "b:def", 1, 15),
      Loc(url: proj1.appendingPathComponent("b.swift"), "a:call", 2, 13),
      Loc(url: proj1.appendingPathComponent("rec").appendingPathComponent("c.swift"), "c", 1, 11),
    ])
  }
}

// MARK: - Oooooollllllld -

func checkThrows(_ expected: IndexStoreDBError, file: StaticString = #file, line: UInt = #line, _ body: () throws -> ()) {
  do {
    try body()
    XCTFail("missing expected error \(expected)", file: file, line: line)

  } catch let error as IndexStoreDBError {

    switch (error, expected) {
    case (.create(let msg), .create(let expected)), (.loadIndexStore(let msg), .loadIndexStore(let expected)):
      XCTAssert(msg.hasPrefix(expected), "error \(error) does not match expected \(expected)", file: file, line: line)
    default:
      XCTFail("error \(error) does not match expected \(expected)", file: file, line: line)
    }
  } catch {
    XCTFail("error \(error) does not match expected \(expected)", file: file, line: line)
  }
}

final class IndexStoreDBTests: XCTestCase {

  var tmp: String = NSTemporaryDirectory()

  override func setUp() {
    tmp += "/indexstoredb_index_test\(getpid())"
  }

  override func tearDown() {
    _ = try? FileManager.default.removeItem(atPath: tmp)
  }

  func testErrors() {
    checkThrows(.create("failed creating directory")) {
      _ = try IndexStoreDB(storePath: "/nope", databasePath: "/nope", library: nil)
    }

    checkThrows(.create("could not determine indexstore library")) {
      _ = try IndexStoreDB(storePath: "\(tmp)/idx", databasePath: "\(tmp)/db", library: nil)
    }
  }

  static var allTests = [
    ("testErrors", testErrors),
    ]
}
