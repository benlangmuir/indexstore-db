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


/// ```
/// {
///   "targets": [
///     {
///       "sources": ["a.swift", "b.swift"]
///     }
///   ]
/// }
/// ```
struct TibsManifest {

  struct Target: Codable {
    var name: String? = nil
    var compiler_arguments: [String]? = nil
    var sources: [String]
    // TODO: dependencies
  }

  var targets: [Target]
}

struct TibsResolvedTarget {
  var name: String
  var extraArgs: [String]
  var sources: [URL]
  var outputNameForUnit: String

  // TODO: dependencies, outputs, import paths, ...
}

final class TibsBuilder {

  var targets: [String: TibsResolvedTarget] = [:]

  enum Error: Swift.Error {
    case duplicateTarget(String)
  }

  init(manifest: TibsManifest, sourceRoot: URL, buildRoot: URL) throws {
    for targetDesc in manifest.targets {
      let name = targetDesc.name ?? "main"

      let target = TibsResolvedTarget(
        name: name,
        extraArgs: targetDesc.compiler_arguments ?? [],
        sources: targetDesc.sources.map { URL(fileURLWithPath: $0) },
        outputNameForUnit: "")

      if targets.updateValue(target, forKey: name) != nil {
        throw Error.duplicateTarget(name)
      }
    }
  }
}

final class SourceFileCache {
  var cache: [URL: String] = [:]

  func get(_ file: URL) throws -> String {
    if let content = cache[file] {
      return content
    }
    let content = try String(contentsOfFile: file.path, encoding: .utf8)
    cache[file] = content
    return content
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

    enum State {
      /// Outside any comment.
      case normal
      /// Outside any comment, immediate after a '/'.
      ///     /X
      ///      ^
      case openSlash
      /// Inside a comment. The payload contains the previous character and the index of the first
      /// character after the '*' (i.e. the start of the comment body).
      ///
      ///       bodyStart
      ///       |
      ///     /*XXX*/
      ///       ^^^
      case comment(bodyStart: String.Index, prev: Character)
    }

    var state = State.normal
    var i = str.startIndex
    var line = 1
    var column = 1

    while i != str.endIndex {
      let c = str[i]

      switch (state, c) {
      case (.normal, "/"):
        state = .openSlash
      case (.normal, _):
        break

      case (.openSlash, "*"):
        state = .comment(bodyStart: str.index(after: i), prev: "_")
      case (.openSlash, "/"):
        break
      case (.openSlash, _):
        state = .normal

      case (.comment(let start, "*"), "/"):
        let name = String(str[start..<str.index(before: i)])
        let loc =  TestLoc(url: url, line: line, column: column + 1)
        if let prevLoc = result.updateValue(loc, forKey: name) {
          throw Error.duplicateKey(name, prevLoc, loc)
        }
        state = .normal

      case (.comment(_, "/"), "*"):
        throw Error.nestedComment(TestLoc(url: url, line: line, column: column))

      case (.comment(let start, _), _):
        state = .comment(bodyStart: start, prev: c)
      }

      if c == "\n" {
        line += 1
        column = 1
      } else {
        column += 1
      }

      i = str.index(after: i)
    }
  }

  mutating func scan(file: URL, sourceCache: SourceFileCache) throws {
    let content = try sourceCache.get(file)
    try scan(content, url: file)
  }

  mutating func scan(rootDirectory: URL, sourceCache: SourceFileCache) throws {
    let fm = FileManager.default

    guard let generator = fm.enumerator(at: rootDirectory, includingPropertiesForKeys: []) else {
      throw Error.noSuchFileOrDirectory(rootDirectory)
    }

    while let url = generator.nextObject() as? URL {
      if isSourceFileExtension(url.pathExtension) {
        try scan(file: url, sourceCache: sourceCache)
      }
    }
  }
}

func scanLocations(rootDirectory: URL, sourceCache: SourceFileCache) throws -> [String: TestLoc] {
  var scanner = LocationScanner()
  try scanner.scan(rootDirectory: rootDirectory, sourceCache: sourceCache)
  return scanner.result
}

final class TestProject {
  var sourceRoot: URL
  let sourceCache: SourceFileCache = SourceFileCache()
  var locations: [String: TestLoc]

  init(sourceRoot: URL) throws {
    self.sourceRoot = sourceRoot
    self.locations = try scanLocations(rootDirectory: sourceRoot, sourceCache: sourceCache)
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
    return try scanLocations(rootDirectory: dir, sourceCache: SourceFileCache())
      .map { key, value in Loc(key, value) }.sorted()
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
