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

import ISDBTibs
import Foundation
import XCTest

final class TibsBuildTests: XCTestCase {

  static let toolchain = TibsToolchain(
    swiftc: findTool(name: "swiftc")!,
    clang: findTool(name: "clang")!,
    tibs: XCTestCase.productsDirectory.appendingPathComponent("tibs", isDirectory: false),
    ninja: findTool(name: "ninja"))

  /// Sleep long enough for file system timestamp to change. For example, older versions of ninja
  /// use 1 second timestamps.
  func sleepForTimestamp() {
    // FIXME: this method is very incomplete. If we're running on a filesystem that doesn't support
    // high resolution time stamps, we'll need to detect that here. This should only be done for
    // testing.
    var usec: UInt32 = 0
    var reason: String = ""
    if TibsBuildTests.toolchain.ninjaVersion < (1, 9, 0) {
      usec = 1_000_000
      reason = "upgrade to ninja >= 1.9.0 for high precision timestamp support"
    }

    if usec > 0 {
      let fsec = Float(usec) / 1_000_000
      fputs("warning: waiting \(fsec) second\(fsec == 1.0 ? "" : "s") to ensure file timestamp " +
            "differs; \(reason)\n", stderr)
      usleep(usec)
    }
  }

  var fm: FileManager = FileManager.default
  var testDir: URL! = nil
  var sourceRoot: URL! = nil
  var buildRoot: URL! = nil

  override func setUp() {
    testDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(testDirectoryName, isDirectory: true)
    buildRoot = testDir.appendingPathComponent("build", isDirectory: true)
    sourceRoot = testDir.appendingPathComponent("src", isDirectory: true)
    
    _ = try? fm.removeItem(at: testDir)
    try! fm.createDirectory(at: buildRoot, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try! fm.removeItem(at: testDir)
  }

  func copyAndLoad(project: String) throws -> TibsBuilder {
    let projSource = projectDir(project)
    try fm.copyItem(at: projSource, to: sourceRoot)
    return try TibsBuilder(
      manifest: try TibsManifest.load(projectRoot: projSource),
      sourceRoot: sourceRoot,
      buildRoot: buildRoot,
      toolchain: TibsBuildTests.toolchain)
  }

  func testBuildSwift() throws {
    let builder = try copyAndLoad(project: "proj1")
    try builder.writeBuildFiles()
    XCTAssertEqual(try builder._buildTest(), ["Swift Module main"])
    XCTAssertEqual(try builder._buildTest(), [])

    let aswift = sourceRoot.appendingPathComponent("a.swift", isDirectory: false)
    let aswift2 = sourceRoot.appendingPathComponent("a.swift-BAK", isDirectory: false)
    try fm.moveItem(at: aswift, to: aswift2)
    XCTAssertThrowsError(try builder._buildTest())

    sleepForTimestamp()
    try fm.moveItem(at: aswift2, to: aswift)
    XCTAssertEqual(try builder._buildTest(), [])

    sleepForTimestamp()
    try "func a() -> Int { 0 }".write(to: aswift, atomically: false, encoding: .utf8)
    XCTAssertEqual(try builder._buildTest(), ["Swift Module main"])
  }

  func testBuildSwiftModules() throws {
    let builder = try copyAndLoad(project: "SwiftModules")
    try builder.writeBuildFiles()
    XCTAssertEqual(try builder._buildTest(), ["Swift Module A", "Swift Module B", "Swift Module C"])
    XCTAssertEqual(try builder._buildTest(), [])

    let bswift = sourceRoot.appendingPathComponent("b.swift", isDirectory: false)
    sleepForTimestamp()
    try "public func bbb() -> Int { 0 }".write(to: bswift, atomically: false, encoding: .utf8)
    XCTAssertEqual(try builder._buildTest(), ["Swift Module B", "Swift Module C"])

    let cswift = sourceRoot.appendingPathComponent("c.swift", isDirectory: false)
    sleepForTimestamp()
    try "import B\nfunc test() { let _: Int = bbb() }".write(to: cswift, atomically: false, encoding: .utf8)
    XCTAssertEqual(try builder._buildTest(), ["Swift Module C"])
    XCTAssertEqual(try builder._buildTest(), [])
  }

  func testBuildMixedLang() throws {
    let builder = try copyAndLoad(project: "MixedLangTarget")
    try builder.writeBuildFiles()

    let bc = sourceRoot.appendingPathComponent("b.c", isDirectory: false)
    let cm = sourceRoot.appendingPathComponent("c.m", isDirectory: false)
    let dcpp = sourceRoot.appendingPathComponent("d.cpp", isDirectory: false)
    let emm = sourceRoot.appendingPathComponent("e.mm", isDirectory: false)

    XCTAssertEqual(try builder._buildTest(),
      ["Swift Module main", bc.path, cm.path, dcpp.path, emm.path])
    XCTAssertEqual(try builder._buildTest(), [])

    let ch = sourceRoot.appendingPathComponent("c.h", isDirectory: false)

    // touch
    var content = try Data(contentsOf: ch)
    content.append(" ".utf8.first!)
    sleepForTimestamp()
    try content.write(to: ch)
    // FIXME: there is a false dependency because of the generated header main-Swift.h
    XCTAssertEqual(try builder._buildTest(),
      ["Swift Module main", bc.path, cm.path, dcpp.path, emm.path])

    sleepForTimestamp()
    let dh = sourceRoot.appendingPathComponent("d.h", isDirectory: false)
    try """
      class D {};
      """.write(to: dh, atomically: false, encoding: .utf8)
    XCTAssertEqual(try builder._buildTest(), [dcpp.path, emm.path])
  }
}

extension XCTestCase {
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
