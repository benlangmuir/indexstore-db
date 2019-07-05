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

import ISDBTestSupport
import Foundation

extension FileHandle: TextOutputStream {
  public func write(_ string: String) {
    guard let data = string.data(using: .utf8) else {
      fatalError("failed to get data from string '\(string)'")
    }
    self.write(data)
  }
}

var stderr = FileHandle.standardError

func main(arguments: [String]) {

  if arguments.count < 2 {
    print("usage: tibs <project-dir>", to: &stderr)
    exit(1)
  }

  let projectDir = URL(fileURLWithPath: arguments.last!, isDirectory: true)
  let manifestURL = projectDir.appendingPathComponent("project.json")

  let manifest: TibsManifest
  do {
    let data = try Data(contentsOf: manifestURL)
    manifest = try JSONDecoder().decode(TibsManifest.self, from: data)
  } catch {
    print("error: could not read manifest '\(manifestURL.path)': \(error)", to: &stderr)
    exit(1)
  }

  let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

  let builder: TibsBuilder
  do {
    builder = try TibsBuilder(manifest: manifest, sourceRoot: projectDir, buildRoot: cwd, toolchain: TibsToolchain(swiftc: URL(fileURLWithPath: "/usr/bin/swiftc")))
  } catch {
    print("error: could not resolve project '\(manifestURL.path)': \(error)", to: &stderr)
    exit(1)
  }

  do {
    try builder.writeBuildFiles()
  } catch {
    print("error: could not write build files: \(error)", to: &stderr)
    exit(1)
  }
}

main(arguments: CommandLine.arguments)
