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

import Foundation

/// The set of commandline tools used to build a tibs project.
public final class TibsToolchain {
  public let swiftc: URL
  public let clang: URL
  public let tibs: URL
  public let ninja: URL?

  public init(swiftc: URL, clang: URL, tibs: URL, ninja: URL? = nil) {
    self.swiftc = swiftc
    self.clang = clang
    self.tibs = tibs
    self.ninja = ninja
  }

  public lazy var clangVersionOutput: String = {
    let p = Process()
    p.launchPath = clang.path
    p.arguments = ["--version"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.launch()
    p.waitUntilExit()
    guard p.terminationReason == .exit && p.terminationStatus == 0 else {
      fatalError("could not get clang --version")
    }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
  }()

  public lazy var clangHasIndexSupport: Bool = {
    clangVersionOutput.starts(with: "Apple") || clangVersionOutput.contains("swift-clang")
  }()
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
