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

public struct TestLoc {
  public var url: URL
  public var line: Int
  public var column: Int
}

public func isSourceFileExtension(_ ext: String) -> Bool {
  switch ext {
    case "swift", "c", "cpp", "m", "mm", "h", "hpp":
      return true
    default:
      return false
  }
}

/// Manifest of a tibs project, describing each target and its dependencies.
///
/// Example:
///
/// ```
/// {
///   "targets": [
///     {
///       "name": "mytarget",
///       "compiler_arguments": ["-warnings-as-errors"],
///       "sources": ["a.swift", "b.swift"]
///     }
///   ]
/// }
/// ```
///
/// As a convenience, if the project consists of a single target, it can be written at the top
/// level. Thus, a minimal manifest is just the list of sources:
///
/// ```
/// { "sources": ["main.swift"] }
/// ```
public struct TibsManifest {

  public struct Target: Codable {
    public var name: String? = nil
    public var compilerArguments: [String]? = nil
    public var sources: [String]
    // TODO: dependencies
  }

  public var targets: [Target]
}

extension TibsManifest: Codable {
  private enum CodingKeys: String, CodingKey {
    case targets
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let targets = try container.decodeIfPresent([Target].self, forKey: .targets) {
      self.targets = targets
    } else {
      self.targets = [try Target(from: decoder)]
    }
  }

  public func encode(to encoder: Encoder) throws {
    if self.targets.count == 1 {
      try self.targets[0].encode(to: encoder)
    } else {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(targets, forKey: .targets)
    }
  }
}

public struct TibsResolvedTarget {
  public var name: String
  public var extraArgs: [String]
  public var sources: [URL]
  public var emitModulePath: String { "\(name).swiftmodule" }
  public var outputFileMap: OutputFileMap
  public var outputFileMapPath: String { "\(name)-output-file-map.json" }

  // TODO: dependencies, outputs, import paths, ...
}

public struct TibsToolchain {
  public var swiftc: URL

  public init(swiftc: URL) {
    self.swiftc = swiftc
  }
}

public struct OutputFileMap {
  public struct Entry: Hashable, Codable {
    public var swiftmodule: String?
    public var swiftdoc: String?

    public var allOutputs: [String] { [swiftmodule, swiftdoc].compactMap{ $0 } }
  }

  public var value: [String: Entry] = [:]

  public var allOutputs: [String] { value.flatMap { key, entry in entry.allOutputs } }

  public subscript(file: String) -> Entry? {
    get { value[file] }
    set { value[file] = newValue }
  }
}

extension OutputFileMap: Codable {
  public init(from decoder: Decoder) throws {
    self.value = try [String: Entry].init(from: decoder)
  }
  public func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }
}

public final class TibsBuilder {

  public var targets: [String: TibsResolvedTarget] = [:]
  public var toolchain: TibsToolchain
  public var buildRoot: URL

  public enum Error: Swift.Error {
    case duplicateTarget(String)
  }

  public init(manifest: TibsManifest, sourceRoot: URL, buildRoot: URL, toolchain: TibsToolchain) throws {
    self.toolchain = toolchain
    self.buildRoot = buildRoot

    for targetDesc in manifest.targets {
      let name = targetDesc.name ?? "main"
      let sources = targetDesc.sources.map {
        URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: sourceRoot)
      }

      var outputFileMap = OutputFileMap()
      for source in sources {
        let basename = source.lastPathComponent
        outputFileMap[source.path] = OutputFileMap.Entry(
          swiftmodule: "\(basename).swiftmodule~partial",
          swiftdoc: "\(basename).swiftdoc~partial"
        )
      }

      let target = TibsResolvedTarget(
        name: name,
        extraArgs: targetDesc.compilerArguments ?? [],
        sources: sources,
        outputFileMap: outputFileMap)

      if targets.updateValue(target, forKey: name) != nil {
        throw Error.duplicateTarget(name)
      }
    }
  }

  public func writeBuildFiles() throws {
    try ninja.write(to: buildRoot.appendingPathComponent("build.ninja"), atomically: false, encoding: .utf8)
    for target in targets.values {
      let encoder = JSONEncoder()
      let ofm = try encoder.encode(target.outputFileMap)
      try ofm.write(to: buildRoot.appendingPathComponent(target.outputFileMapPath))
    }
  }

  public var ninja: String {
    var result = ""
    writeNinja(to: &result)
    return result
  }

  public func writeNinja<Output: TextOutputStream>(to stream: inout Output) {
    writeNinjaHeader(to: &stream)
    stream.write("\n\n")
    writeNinjaRules(to: &stream)
    stream.write("\n\n")
    for target in targets.values {
      writeNinjaSnippet(for: target, to: &stream)
      stream.write("\n\n")
    }
  }

  public func writeNinjaHeader<Output: TextOutputStream>(to stream: inout Output) {
    stream.write("""
      # Generated by tibs. DO NOT EDIT!
      ninja_required_version = 1.5
      """)
  }

  public func writeNinjaRules<Output: TextOutputStream>(to stream: inout Output) {
    stream.write("""
      rule swiftc_index
        description = Indexing Swift Module $MODULE_NAME
        command = \(toolchain.swiftc.path) -module-name $MODULE_NAME $in -index-store-path index -index-ignore-system-modules -output-file-map $OUTPUT_FILE_MAP -emit-module -emit-module-path $MODULE_PATH $EXTRA_ARGS
        restat = 1 # Swift doesn't rewrite modules that haven't changed
      """)
  }

  public func writeNinjaSnippet<Output: TextOutputStream>(for target: TibsResolvedTarget, to stream: inout Output) {
    let outputs = [target.emitModulePath]
    // FIXME: some of these are deleted by the compiler!?
    // outputs += target.outputFileMap.allOutputs

    // TODO:
    // * dependency on compiler
    // * dependencies
    stream.write("""
      build \(outputs.joined(separator: " ")): \
      swiftc_index \(target.sources.map{ $0.path }.joined(separator: " ")) \
      | \(target.outputFileMapPath)
        MODULE_NAME = \(target.name)
        MODULE_PATH = \(target.emitModulePath)
        EXTRA_ARGS = \(target.extraArgs.joined(separator: " "))
        OUTPUT_FILE_MAP = \(target.outputFileMapPath)
      """)
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

public final class TestProject {
  public var sourceRoot: URL
  public let sourceCache: SourceFileCache = SourceFileCache()
  public var locations: [String: TestLoc]

  public init(sourceRoot: URL) throws {
    self.sourceRoot = sourceRoot
    self.locations = try scanLocations(rootDirectory: sourceRoot, sourceCache: sourceCache)
  }
}
