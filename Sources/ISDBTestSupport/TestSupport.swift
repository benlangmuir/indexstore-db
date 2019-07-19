//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import IndexStoreDB
import ISDBTibs
import Foundation
import XCTest

public struct TestLoc: Hashable {
  public var url: URL
  public var line: Int
  public var column: Int

  public init(url: URL, line: Int, column: Int) {
    self.url = url
    self.line = line
    self.column = column
  }
}

extension TestLoc: Comparable {
  public static func <(a: TestLoc, b: TestLoc) -> Bool {
    return (a.url.path, a.line, a.column) < (b.url.path, b.line, b.column)
  }
}

extension TestLoc {
  public init(_ location: SymbolLocation) {
    self.init(
      url: URL(fileURLWithPath: location.path),
      line: location.line,
      column: location.utf8Column)
  }
}

extension SymbolLocation {
  public init(_ loc: TestLoc, isSystem: Bool = false) {
    self.init(
      path: loc.url.path,
      isSystem: isSystem,
      line: loc.line,
      utf8Column: loc.column)
  }
}

extension TestLoc: CustomStringConvertible {
  public var description: String { "\(url.path):\(line):\(column)" }
}

public func isSourceFileExtension(_ ext: String) -> Bool {
  switch ext {
    case "swift", "c", "cpp", "m", "mm", "h", "hpp":
      return true
    default:
      return false
  }
}

public final class SourceFileCache {
  var cache: [URL: String] = [:]

  public init(_ cache: [URL: String] = [:]) {
    self.cache = cache
  }

  public func get(_ file: URL) throws -> String {
    if let content = cache[file] {
      return content
    }
    let content = try String(contentsOfFile: file.path, encoding: .utf8)
    cache[file] = content
    return content
  }

  public func set(_ file: URL, to content: String?) {
    cache[file] = content
  }
}

public struct LocationScanner {
  public var result: [String: TestLoc] = [:]

  public init() {}

  public enum Error: Swift.Error {
    case noSuchFileOrDirectory(URL)
    case nestedComment(TestLoc)
    case duplicateKey(String, TestLoc, TestLoc)
  }

  public mutating func scan(_ str: String, url: URL) throws {
    if str.count < 4 {
      return
    }

    enum State {
      /// Outside any comment.
      case normal(prev: Character)

      /// Inside a comment. The payload contains the previous character and the index of the first
      /// character after the '*' (i.e. the start of the comment body).
      ///
      ///       bodyStart
      ///       |
      ///     /*XXX*/
      ///       ^^^
      case comment(bodyStart: String.Index, prev: Character)
    }

    var state = State.normal(prev: "_")
    var i = str.startIndex
    var line = 1
    var column = 1

    while i != str.endIndex {
      let c = str[i]

      switch (state, c) {
      case (.normal("/"), "*"):
        state = .comment(bodyStart: str.index(after: i), prev: "_")
      case (.normal(_), _):
        state = .normal(prev: c)

      case (.comment(let start, "*"), "/"):
        let name = String(str[start..<str.index(before: i)])
        let loc =  TestLoc(url: url, line: line, column: column + 1)
        if let prevLoc = result.updateValue(loc, forKey: name) {
          throw Error.duplicateKey(name, prevLoc, loc)
        }
        state = .normal(prev: "_")

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

  public mutating func scan(file: URL, sourceCache: SourceFileCache) throws {
    let content = try sourceCache.get(file)
    try scan(content, url: file)
  }

  public mutating func scan(rootDirectory: URL, sourceCache: SourceFileCache) throws {
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

public func scanLocations(rootDirectory: URL, sourceCache: SourceFileCache) throws -> [String: TestLoc] {
  var scanner = LocationScanner()
  try scanner.scan(rootDirectory: rootDirectory, sourceCache: sourceCache)
  return scanner.result
}

public final class TestSources {
  public var rootDirectory: URL
  public let sourceCache: SourceFileCache = SourceFileCache()
  public var locations: [String: TestLoc]

  public init(rootDirectory: URL) throws {
    self.rootDirectory = rootDirectory
    self.locations = try scanLocations(rootDirectory: rootDirectory, sourceCache: sourceCache)
  }

  public struct ChangeSet {
    public var remove: [URL] = []
    public var rename: [(URL, URL)] = []
    public var write: [(URL, String)] = []

    public func isDirty(_ url: URL) -> Bool {
      return remove.contains(url)
        || rename.contains { $0 == url || $1 == url }
        || write.contains { $0.0 == url }
    }
  }

  public struct ChangeBuilder {
    public var changes: ChangeSet = ChangeSet()
    var seen: Set<URL> = []

    public mutating func write(_ content: String, to url: URL) {
      precondition(seen.insert(url).inserted, "multiple edits to same file")
      changes.write.append((url, content))
    }
    public mutating func remove(_ url: URL) {
      precondition(seen.insert(url).inserted, "multiple edits to same file")
      changes.remove.append(url)
    }
    public mutating func rename(from: URL, to: URL) {
      precondition(seen.insert(from).inserted && seen.insert(to).inserted, "multiple edits to same file")
      changes.rename.append((from, to))
    }
  }

  public func apply(_ changes: ChangeSet) throws {
    for (url, content) in changes.write {
      guard let data = content.data(using: .utf8) else {
        fatalError("failed to encode edited contents to utf8")
      }
      try data.write(to: url)
      sourceCache.set(url, to: content)
    }

    let fm = FileManager.default
    for (from, to) in changes.rename {
      try fm.moveItem(at: from, to: to)
      sourceCache.set(to, to: sourceCache.cache[from])
      sourceCache.set(from, to: nil)
    }

    for url in changes.remove {
      try fm.removeItem(at: url)
      sourceCache.set(url, to: nil)
    }

    // FIXME: update incrementally without rescanning everything.
    locations = try scanLocations(rootDirectory: rootDirectory, sourceCache: sourceCache)
  }

  public func edit(_ block: (inout ChangeBuilder) throws -> ()) throws -> ChangeSet {
    var builder = ChangeBuilder()
    try block(&builder)
    try apply(builder.changes)
    return builder.changes
  }
}

public final class TibsTestWorkspace {

  public static let defaultToolchain = TibsToolchain(
    swiftc: findTool(name: "swiftc")!,
    clang: findTool(name: "clang")!,
    tibs: XCTestCase.productsDirectory.appendingPathComponent("tibs", isDirectory: false),
    ninja: findTool(name: "ninja"))

  /// The directory containing the original, unmodified project.
  public let projectDir: URL

  /// A test-specific directory that we can put temporary files into.
  public let tmpDir: URL

  /// Whether the sources can be modified during this test. If this is true, we can call `edit()`.
  public let mutableSources: Bool

  /// The source files used by the test. If `mutableSources == false`, they are located in
  /// `projectDir`. Otherwise, they are copied to a temporary location.
  public let sources: TestSources

  /// The current resolved project and builder.
  public var builder: TibsBuilder

  /// The source code index.
  public var index: IndexStoreDB

  /// Creates a tibs test workspace for a given project with immutable sources and a build directory
  /// that can persist across test runs (typically inside the main project build directory).
  ///
  /// The `edit()` method is disallowed.
  ///
  /// * parameters:
  ///   * immutableProjectDir: The directory containing the project.
  ///   * persistentBuildDir: The directory to build in.
  ///   * tmpDir: A test-specific directory that we can put temporary files into. Will be cleared
  ///       by `deinit`.
  ///   * toolchain: The toolchain to use for building and indexing.
  ///
  /// * throws: If there are any file system errors.
  public init(
    immutableProjectDir: URL,
    persistentBuildDir: URL,
    tmpDir: URL,
    toolchain: TibsToolchain) throws
  {
    self.projectDir = immutableProjectDir
    self.tmpDir = tmpDir
    self.mutableSources = false

    let fm = FileManager.default
    _ = try? fm.removeItem(at: tmpDir)

    try fm.createDirectory(at: persistentBuildDir, withIntermediateDirectories: true, attributes: nil)
    let databaseDir = tmpDir
    try fm.createDirectory(at: databaseDir, withIntermediateDirectories: true, attributes: nil)

    self.sources = try TestSources(rootDirectory: projectDir)

    let manifest = try TibsManifest.load(projectRoot: projectDir)
    builder = try TibsBuilder(
      manifest: manifest,
      sourceRoot: projectDir,
      buildRoot: persistentBuildDir,
      toolchain: toolchain)

    try fm.createDirectory(at: builder.indexstore, withIntermediateDirectories: true, attributes: nil)

    try builder.writeBuildFiles()

    let libIndexStore = try IndexStoreLibrary(dylibPath: toolchain.libIndexStore.path)

    self.index = try IndexStoreDB(
      storePath: builder.indexstore.path,
      databasePath: tmpDir.path,
      library: libIndexStore,
      listenToUnitEvents: false)
  }

  /// Creates a tibs test workspace and copies the sources to a temporary location so that they can
  /// be modified (using `edit()`) and rebuilt during the test.
  ///
  /// * parameters:
  ///   * projectDir: The directory containing the project. The sources will be copied to a
  ///       temporary location.
  ///   * tmpDir: A test-specific directory that we can put temporary files into. Will be cleared
  ///       by `deinit`.
  ///   * toolchain: The toolchain to use for building and indexing.
  ///
  /// * throws: If there are any file system errors.
  public init(projectDir: URL, tmpDir: URL, toolchain: TibsToolchain) throws {
    self.projectDir = projectDir
    self.tmpDir = tmpDir
    self.mutableSources = true

    let fm = FileManager.default
    _ = try? fm.removeItem(at: tmpDir)

    let buildDir = tmpDir.appendingPathComponent("build", isDirectory: true)
    try fm.createDirectory(at: buildDir, withIntermediateDirectories: true, attributes: nil)
    let sourceDir = tmpDir.appendingPathComponent("src", isDirectory: true)
    try fm.copyItem(at: projectDir, to: sourceDir)
    let databaseDir = tmpDir.appendingPathComponent("db", isDirectory: true)
    try fm.createDirectory(at: databaseDir, withIntermediateDirectories: true, attributes: nil)

    self.sources = try TestSources(rootDirectory: sourceDir)

    let manifest = try TibsManifest.load(projectRoot: projectDir)
    builder = try TibsBuilder(
      manifest: manifest,
      sourceRoot: sourceDir,
      buildRoot: buildDir,
      toolchain: toolchain)

    try fm.createDirectory(at: builder.indexstore, withIntermediateDirectories: true, attributes: nil)

    try builder.writeBuildFiles()

    let libIndexStore = try IndexStoreLibrary(dylibPath: toolchain.libIndexStore.path)

    self.index = try IndexStoreDB(
      storePath: builder.indexstore.path,
      databasePath: tmpDir.path,
      library: libIndexStore,
      listenToUnitEvents: false)
  }

  deinit {
    _ = try? FileManager.default.removeItem(atPath: tmpDir.path)
  }

  public func buildAndIndex() throws {
     try builder.build()
     index.pollForUnitChangesAndWait()
   }

  public func testLoc(_ name: String) -> TestLoc { sources.locations[name]! }

  /// Perform a group of edits to the project sources and optionally rebuild.
  public func edit(
    rebuild: Bool = false,
    _ block: (inout TestSources.ChangeBuilder, _ current: SourceFileCache) throws -> ()) throws
  {
    precondition(mutableSources, "tried to edit in immutable workspace")
    builder.toolchain.sleepForTimestamp()

    let cache = sources.sourceCache
    _ = try sources.edit { builder in
      try block(&builder, cache)
    }
    // FIXME: support editing the project.json and update the build settings.
    if rebuild {
      try buildAndIndex()
    }
  }
}

extension XCTestCase {

  /// Returns nil and prints a warning if toolchain does not support this test.
  public func staticTibsTestWorkspace(name: String, testFile: String = #file) throws -> TibsTestWorkspace? {
    let testDirName = testDirectoryName

    let toolchain = TibsTestWorkspace.defaultToolchain

    let workspace = try TibsTestWorkspace(
      immutableProjectDir: inputsDirectory(testFile: testFile)
        .appendingPathComponent(name, isDirectory: true),
      persistentBuildDir: XCTestCase.productsDirectory
        .appendingPathComponent("isdb-tests/\(testDirName)", isDirectory: true),
      tmpDir: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("isdb-test-data/\(testDirName)", isDirectory: true),
      toolchain: toolchain)

    if workspace.builder.targets.contains(where: { target in !target.clangTUs.isEmpty })
      && !toolchain.clangHasIndexSupport {
      fputs("warning: skipping test because '\(toolchain.clang.path)' does not have indexstore " +
            "support; use swift-clang\n", stderr)
      return nil
    }

    return workspace
  }

  /// Returns nil and prints a warning if toolchain does not support this test.
   public func mutableTibsTestWorkspace(name: String, testFile: String = #file) throws -> TibsTestWorkspace? {
     let testDirName = testDirectoryName

     let toolchain = TibsTestWorkspace.defaultToolchain

     let workspace = try TibsTestWorkspace(
       projectDir: inputsDirectory(testFile: testFile)
         .appendingPathComponent(name, isDirectory: true),
       tmpDir: URL(fileURLWithPath: NSTemporaryDirectory())
         .appendingPathComponent("isdb-test-data/\(testDirName)", isDirectory: true),
       toolchain: toolchain)

     if workspace.builder.targets.contains(where: { target in !target.clangTUs.isEmpty })
       && !toolchain.clangHasIndexSupport {
       fputs("warning: skipping test because '\(toolchain.clang.path)' does not have indexstore " +
             "support; use swift-clang\n", stderr)
       return nil
     }

     return workspace
   }

  /// The path the the test INPUTS directory.
  public func inputsDirectory(testFile: String = #file) -> URL {
    return URL(fileURLWithPath: testFile)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("INPUTS", isDirectory: true)
  }

  /// The path to the built products directory.
  public static var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
          return bundle.bundleURL.deletingLastPathComponent()
      }
      fatalError("couldn't find the products directory")
    #else
      return Bundle.main.bundleURL
    #endif
  }

  /// The name of this test, mangled for use as a directory.
  public var testDirectoryName: String {
    guard name.starts(with: "-[") else {
      return name
    }

    let className = name.dropFirst(2).prefix(while: { $0 != " " })
    let methodName = name[className.endIndex...].dropFirst().prefix(while: { $0 != "]"})
    return "\(className).\(methodName)"
  }
}

extension Symbol {
  public func with(name: String? = nil, usr: String? = nil, kind: Kind? = nil) -> Symbol {
    return Symbol(usr: usr ?? self.usr, name: name ?? self.name, kind: kind ?? self.kind)
  }

  public func at(_ location: TestLoc, roles: SymbolRole) -> SymbolOccurrence {
    return self.at(SymbolLocation(location), roles: roles)
  }

  public func at(_ location: SymbolLocation, roles: SymbolRole) -> SymbolOccurrence {
    return SymbolOccurrence(symbol: self, location: location, roles: roles)
  }
}

public func checkOccurrences(
  _ occurs: [SymbolOccurrence],
  ignoreRelations: Bool = true,
  allowAdditionalRoles: Bool = true,
  expected: [SymbolOccurrence],
  file: StaticString = #file,
  line: UInt = #line)
{
  var expected: [SymbolOccurrence] = expected
  var actual: [SymbolOccurrence] = occurs

  if ignoreRelations {
    for i in expected.indices {
      expected[i].relations = []
    }
    for i in actual.indices {
      actual[i].relations = []
    }
  }

  expected.sort()
  actual.sort()

  var ai = actual.startIndex
  let aend = actual.endIndex
  var ei = expected.startIndex
  let eend = expected.endIndex

  func compare(actual: SymbolOccurrence, expected: SymbolOccurrence) -> ComparisonResult {
    var actual = actual
    if allowAdditionalRoles {
      actual.roles.formIntersection(expected.roles)
    }

    if actual == expected { return .orderedSame }
    if actual < expected { return .orderedAscending }
    return .orderedDescending
  }

  while ai != aend && ei != eend {
    switch compare(actual: actual[ai], expected: expected[ei]) {
    case .orderedSame:
      actual.formIndex(after: &ai)
      expected.formIndex(after: &ei)
    case .orderedAscending:
      XCTFail("unexpected symbol occurrence \(actual[ai])", file: file, line: line)
      actual.formIndex(after: &ai)
    case .orderedDescending:
      XCTFail("missing expected symbol occurrence \(expected[ei])", file: file, line: line)
      expected.formIndex(after: &ei)
    }
  }

  while ai != aend {
    XCTFail("unexpected symbol occurrence \(actual[ai])", file: file, line: line)
    actual.formIndex(after: &ai)
  }

  while ei != eend {
    XCTFail("missing expected symbol occurrence \(expected[ei])", file: file, line: line)
    expected.formIndex(after: &ei)
  }
}
