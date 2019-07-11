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
}

public final class StaticTibsTestWorkspace {

  public static let defaultToolchain = TibsToolchain(
    swiftc: findTool(name: "swiftc")!,
    clang: findTool(name: "clang")!,
    ninja: findTool(name: "ninja"))

  public var sources: TestSources
  public var builder: TibsBuilder
  public var index: IndexStoreDB
  public let tmpDir: URL

  public init(projectDir: URL, buildDir: URL, tmpDir: URL, toolchain: TibsToolchain = StaticTibsTestWorkspace.defaultToolchain) throws {
    sources = try TestSources(rootDirectory: projectDir)

    let fm = FileManager.default
    try fm.createDirectory(at: buildDir, withIntermediateDirectories: true, attributes: nil)

    let manifestURL = projectDir.appendingPathComponent("project.json")
    let manifest = try JSONDecoder().decode(TibsManifest.self, from: try Data(contentsOf: manifestURL))
    builder = try TibsBuilder(manifest: manifest, sourceRoot: projectDir, buildRoot: buildDir, toolchain: toolchain)

    try builder.writeBuildFiles()
    try fm.createDirectory(at: builder.indexstore, withIntermediateDirectories: true, attributes: nil)

    let libIndexStore = try IndexStoreLibrary(dylibPath: toolchain.swiftc
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("lib")
      .appendingPathComponent("libIndexStore.dylib")
      .path) // FIXME: non-Mac

    self.tmpDir = tmpDir

    index = try IndexStoreDB(
      storePath: builder.indexstore.path,
      databasePath: tmpDir.path,
      library: libIndexStore, listenToUnitEvents: false)
  }

  deinit {
    _ = try? FileManager.default.removeItem(atPath: tmpDir.path)
  }
}

extension StaticTibsTestWorkspace {

  public func buildAndIndex() throws {
    try builder.build()
    index.pollForUnitChangesAndWait()
  }
}

extension StaticTibsTestWorkspace {

  public func testLoc(_ name: String) -> TestLoc { sources.locations[name]! }
}

extension XCTestCase {

  public func staticTibsTestWorkspace(name: String, testFile: String = #file) throws -> StaticTibsTestWorkspace {
    let testDirName = testDirectoryName
    return try StaticTibsTestWorkspace(
      projectDir: inputsDirectory(testFile: testFile).appendingPathComponent(name),
      buildDir: productsDirectory
        .appendingPathComponent("isdb-tests")
        .appendingPathComponent(testDirName),
      tmpDir: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("idsb-test-data")
        .appendingPathComponent(testDirName))
  }

  /// The path the the test INPUTS directory.
  public func inputsDirectory(testFile: String = #file) -> URL {
    return URL(fileURLWithPath: testFile)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("INPUTS")
  }

  /// The path to the built products directory.
  public var productsDirectory: URL {
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

/// Returns the path to the given tool, as found by `xcrun --find` on macOS, or `which` on Linux.
public func findTool(name: String) -> URL? {
  let p = Process()
#if os(macOS)
  p.launchPath = "/usr/bin/xcrun"
  p.arguments = ["--find", name]
#else
  p.launchPath = "/usr/bin/which"
  p.arguments = [name]
#endif
  let out = Pipe()
  p.standardOutput = out

  p.launch()
  p.waitUntilExit()

  if p.terminationReason != .exit || p.terminationStatus != 0 {
    return nil
  }

  let data = out.fileHandleForReading.readDataToEndOfFile()
  guard var path = String(data: data, encoding: .utf8) else {
    return nil
  }
  if path.last == "\n" {
    path = String(path.dropLast())
  }
  return URL(fileURLWithPath: path)
}
