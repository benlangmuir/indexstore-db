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

final class TibsTests: XCTestCase {

  func testBasic() throws {
    let buildDir = productsDirectory
      .appendingPathComponent("isdb-tests")
      .appendingPathComponent(testDirectoryName)
    let fm = FileManager.default
    try fm.createDirectory(at: buildDir, withIntermediateDirectories: true, attributes: nil)

    let tc = TibsToolchain(
      swiftc: findTool(name: "swiftc")!,
      ninja: findTool(name: "ninja"))

    let projectDir = inputsDirectory.appendingPathComponent("proj1")

    let project = try TestProject(sourceRoot: projectDir)

    let manifestURL = projectDir.appendingPathComponent("project.json")
    let manifest = try JSONDecoder().decode(TibsManifest.self, from: try Data(contentsOf: manifestURL))
    let builder = try TibsBuilder(manifest: manifest, sourceRoot: projectDir, buildRoot: buildDir, toolchain: tc)

    try builder.writeBuildFiles()

    try builder.build()

    // -------

    let libIndexStore = try IndexStoreLibrary(dylibPath: tc.swiftc
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("lib")
      .appendingPathComponent("libIndexStore.dylib")
      .path) // FIXME: non-Mac

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("idsb-test-data")
      .appendingPathComponent(testDirectoryName)

    defer { _ = try? fm.removeItem(atPath: tmpDir.path) }

    let index = try IndexStoreDB(
      storePath: builder.indexstore.path,
      databasePath: tmpDir.path,
      library: libIndexStore, listenToUnitEvents: false)

    XCTAssertEqual(0, index.occurrences(ofUSR: "s:4main1cyyF", roles: [.reference, .definition]).count)

    index.pollForUnitChangesAndWait()

    let occs = index.occurrences(ofUSR: "s:4main1cyyF", roles: [.reference, .definition])
    XCTAssertEqual(2, occs.count)
    XCTAssertEqual(occs[0].symbol.name, "c()")
    XCTAssertEqual(occs[0].symbol.usr, "s:4main1cyyF")
    if occs[0].roles.contains(.definition) {
      XCTAssertEqual(occs[0].roles, [.definition, .canonical])
      let loc = project.locations["c"]!
      XCTAssertEqual(occs[0].location, SymbolLocation(path: loc.url.path, isSystem: false, line: loc.line, utf8Column: loc.column))
    } else {
      let loc = project.locations["c:call"]!
      XCTAssertEqual(occs[0].location, SymbolLocation(path: loc.url.path, isSystem: false, line: loc.line, utf8Column: loc.column))
    }
  }

  /// The path the the test INPUTS directory.
  lazy var inputsDirectory: URL = {
    return URL(fileURLWithPath: #file)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("INPUTS")
  }()

  /// The path to the built products directory.
  lazy var productsDirectory: URL = {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
          return bundle.bundleURL.deletingLastPathComponent()
      }
      fatalError("couldn't find the products directory")
    #else
      return Bundle.main.bundleURL
    #endif
  }()

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
