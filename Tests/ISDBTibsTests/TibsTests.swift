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

final class TibsTests: XCTestCase {

  static let fakeToolchain: TibsToolchain = TibsToolchain(
    swiftc: URL(fileURLWithPath: "/swiftc"),
    clang: URL(fileURLWithPath: "/clang"),
    tibs: URL(fileURLWithPath: "/tibs"),
    ninja: URL(fileURLWithPath: "/ninja"))

  func testResolutionSingleSwiftModule() throws {
    let dir = projectDir("proj1")
    let m = try manifest(projectDir: dir)
    let tc = TibsTests.fakeToolchain
    let src = URL(fileURLWithPath: "/src", isDirectory: true)
    let build = URL(fileURLWithPath: "/build", isDirectory: true)
    let builder = try TibsBuilder(manifest: m, sourceRoot: src, buildRoot: build, toolchain: tc)

    XCTAssertEqual(1, builder.targets.count)
    guard let target = builder.targets.first else {
      return
    }
    XCTAssertEqual(target.name, "main")
    XCTAssertEqual(target.dependencies, [])
    XCTAssertEqual(target.clangTUs, [])
    XCTAssertNotNil(target.swiftModule)
    guard let module = target.swiftModule else {
      return
    }
    XCTAssertEqual(module.name, "main")
    XCTAssertEqual(module.emitModulePath, "main.swiftmodule")
    XCTAssertNil(module.emitHeaderPath)
    XCTAssertNil(module.bridgingHeader)
    XCTAssertEqual(module.moduleDeps, [])
    XCTAssertEqual(module.importPaths, [])
    XCTAssertEqual(module.extraArgs, [])
    XCTAssertEqual(module.sources, [
      src.appendingPathComponent("a.swift", isDirectory: false),
      src.appendingPathComponent("b.swift", isDirectory: false),
      src.appendingPathComponent("rec/c.swift" , isDirectory: false),
    ])
  }

  func testResolutionMixedLangTarget() throws {
    let dir = projectDir("MixedLangTarget")
    let m = try manifest(projectDir: dir)
    let tc = TibsTests.fakeToolchain
    let src = URL(fileURLWithPath: "/src", isDirectory: true)
    let build = URL(fileURLWithPath: "/build", isDirectory: true)
    let builder = try TibsBuilder(manifest: m, sourceRoot: src, buildRoot: build, toolchain: tc)

    XCTAssertEqual(1, builder.targets.count)
    guard let target = builder.targets.first else {
      return
    }
    XCTAssertEqual(target.name, "main")
    XCTAssertEqual(target.dependencies, [])
    XCTAssertNotNil(target.swiftModule)
    guard let module = target.swiftModule else {
      return
    }
    XCTAssertEqual(module.name, "main")
    XCTAssertEqual(module.emitModulePath, "main.swiftmodule")
    XCTAssertEqual(module.emitHeaderPath, "main-Swift.h")
    XCTAssertEqual(module.bridgingHeader,
                   src.appendingPathComponent("bridging-header.h", isDirectory: false))
    XCTAssertEqual(module.moduleDeps, [])
    XCTAssertEqual(module.importPaths, [])
    XCTAssertEqual(module.extraArgs, ["-Xcc", "-Wno-objc-root-class"])
    XCTAssertEqual(module.sources, [
      src.appendingPathComponent("a.swift", isDirectory: false),
      src.appendingPathComponent("b.swift", isDirectory: false),
    ])

    // TODO: clangTUs
  }

  // Compilation Database tests

  // Build
  //
  // Null and non-null rebuild
  // * Header change
  // * Source file change
  // * OFM change
  // * Ninja changes
}

func projectDir(_ name: String) -> URL {
  return URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("INPUTS/\(name)", isDirectory: true)
}

func manifest(projectDir: URL) throws -> TibsManifest {
  let manifestData = try Data(
    contentsOf: projectDir.appendingPathComponent("project.json", isDirectory: false))
  return try JSONDecoder().decode(TibsManifest.self, from:  manifestData)
}
