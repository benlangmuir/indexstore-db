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

extension FileHandle: TextOutputStream {
  public func write(_ string: String) {
    guard let data = string.data(using: .utf8) else {
      fatalError("failed to get data from string '\(string)'")
    }
    self.write(data)
  }
}

var stderr = FileHandle.standardError

func swiftDepsMerge(output: String, _ files: [String]) {
  var allDeps: Set<Substring> = []
  for file in files {
    let content: String
    do {
      content = try String(contentsOf: URL(fileURLWithPath: file))
    } catch {
      print("error: could not read dep file '\(file)': \(error)", to: &stderr)
      exit(1)
    }

    let lines = content.split(whereSeparator: { $0.isNewline })
    for line in lines {
      guard let depStr = line.split(separator: ":", maxSplits: 1).last else {
        print("error: malformed dep file '\(file)': expected :", to: &stderr)
        exit(1)
      }

      let deps = depStr.split(whereSeparator: { $0.isWhitespace })
      for dep in deps {
        allDeps.insert(dep)
      }
    }
  }

  print("\(output) : \(allDeps.sorted().joined(separator: " "))")
}

func main(arguments: [String]) {

  if arguments.count < 2 {
    print("usage: tibs <project-dir>", to: &stderr)
    exit(1)
  }

  if arguments[1] == "swift-deps-merge" {
    if arguments.count < 4 {
      print("usage: tibs swift-deps-merge <output> <deps1.d> [...]", to: &stderr)
      exit(1)
    }
    swiftDepsMerge(output: arguments[2], Array(arguments.dropFirst(3)))
    return
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

  let toolchain = TibsToolchain(
    swiftc: URL(fileURLWithPath: "/usr/bin/swiftc"),
    clang: URL(fileURLWithPath: "/usr/bin/clang"),
    tibs: Bundle.main.bundleURL.appendingPathComponent("tibs"))

  let builder: TibsBuilder
  do {
    builder = try TibsBuilder(manifest: manifest, sourceRoot: projectDir, buildRoot: cwd, toolchain: toolchain)
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
