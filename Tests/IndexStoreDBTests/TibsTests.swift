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
import ISDBTestSupport
import XCTest

final class StaticTibsTestWorkspace {

  public static let defaultToolchain = TibsToolchain(
    swiftc: findTool(name: "swiftc")!,
    ninja: findTool(name: "ninja"))

  public var sources: TestSources
  public var builder: TibsBuilder
  public var index: IndexStoreDB
  public let tmpDir: URL

  init(projectDir: URL, buildDir: URL, tmpDir: URL, toolchain: TibsToolchain = StaticTibsTestWorkspace.defaultToolchain) throws {
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
  func staticTibsTestWorkspace(name: String) throws -> StaticTibsTestWorkspace {
    let testDirName = testDirectoryName
    return try StaticTibsTestWorkspace(
      projectDir: inputsDirectory.appendingPathComponent(name),
      buildDir: productsDirectory
        .appendingPathComponent("isdb-tests")
        .appendingPathComponent(testDirName),
      tmpDir: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("idsb-test-data")
        .appendingPathComponent(testDirName))
  }

  /// The path the the test INPUTS directory.
  var inputsDirectory: URL {
    return URL(fileURLWithPath: #file)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("INPUTS")
  }

  /// The path to the built products directory.
  var productsDirectory: URL {
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
  var testDirectoryName: String {
    guard name.starts(with: "-[") else {
      return name
    }

    let className = name.dropFirst(2).prefix(while: { $0 != " " })
    let methodName = name[className.endIndex...].dropFirst().prefix(while: { $0 != "]"})
    return "\(className).\(methodName)"
  }
}

final class TibsTests: XCTestCase {

  func testBasic() throws {
    let ws = try staticTibsTestWorkspace(name: "proj1")
    let index = ws.index

    let getOccs = { index.occurrences(ofUSR: "s:4main1cyyF", roles: [.reference, .definition]) }

    XCTAssertEqual(0, getOccs().count)

    try ws.buildAndIndex()

    let occs = getOccs()
    XCTAssertEqual(2, occs.count)
    guard occs.count == 2 else { return }

    XCTAssertEqual(occs[0].symbol.name, "c()")
    XCTAssertEqual(occs[0].symbol.usr, "s:4main1cyyF")
    if occs[0].roles.contains(.definition) {
      XCTAssertEqual(occs[0].roles, [.definition, .canonical])
      let loc = ws.testLoc("c")
      XCTAssertEqual(occs[0].location, SymbolLocation(path: loc.url.path, isSystem: false, line: loc.line, utf8Column: loc.column))
    } else {
      let loc = ws.testLoc("c:call")
      XCTAssertEqual(occs[0].location, SymbolLocation(path: loc.url.path, isSystem: false, line: loc.line, utf8Column: loc.column))
    }
  }
}

/// Returns the path to the given tool, as found by `xcrun --find` on macOS, or `which` on Linux.
func findTool(name: String) -> URL? {
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
