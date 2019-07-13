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

  static let ninjaVersion: (Int, Int, Int) = {
    let p = Process()
    p.launchPath = TibsBuildTests.toolchain.ninja!.path
    p.arguments = ["--version"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.launch()
    p.waitUntilExit()
    guard p.terminationReason == .exit && p.terminationStatus == 0 else {
      fatalError("could not get ninja --version")
    }

    var out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = out.split(separator: ".", maxSplits: 3)
    guard let maj = Int(String(components[0])),
          let min = Int(String(components[1])),
          let patch = components.count > 2 ? Int(String(components[2])) : 0
    else {
      fatalError("could not parsed ninja --version '\(out)'")
    }
    return (maj, min, patch)
  }()

  /// Sleep long enough for file system timestamp to change. For example, older versions of ninja
  /// use 1 second timestamps.
  func sleepForTimestamp() {
    // FIXME: this method is very incomplete. If we're running on a filesystem that doesn't support
    // high resolution time stamps, we'll need to detect that here. This should only be done for
    // testing.
    var usec: UInt32 = 1
    if TibsBuildTests.ninjaVersion < (1, 9, 0) {
      usec = 1_000_000
    }
    usleep(usec)
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
      manifest: try manifest(projectDir: projSource),
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

    try fm.moveItem(at: aswift2, to: aswift)
    sleepForTimestamp()
    XCTAssertEqual(try builder._buildTest(), [])

    try "func a() -> Int { 0 }".write(to: aswift, atomically: false, encoding: .utf8)
    sleepForTimestamp()
    XCTAssertEqual(try builder._buildTest(), ["Swift Module main"])
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
