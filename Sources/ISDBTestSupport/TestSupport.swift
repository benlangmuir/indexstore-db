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
import Foundation
import XCTest

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
///       "swift_flags": ["-warnings-as-errors"],
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

  public struct Target {
    public var name: String? = nil
    public var swiftFlags: [String]? = nil
    public var clangFlags: [String]? = nil
    public var sources: [String]
    public var bridgingHeader: String? = nil
    public var dependencies: [String]? = nil
  }

  public var targets: [Target]
}

extension TibsManifest.Target: Codable {
  private enum CodingKeys: String, CodingKey {
    case name
    case swiftFlags = "swift_flags"
    case clangFlags = "clang_flags"
    case sources
    case bridgingHeader = "bridging_header"
    case dependencies
  }
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

public enum TibsCompileUnit {
  case swiftModule(SwiftModule)
  case clangTranslationUnit(ClangTU)

  public struct SwiftModule {
    public var name: String
    public var extraArgs: [String]
    public var sources: [URL]
    public var emitModulePath: String { "\(name).swiftmodule" }
    // FIXME: emitObjCHeaderPath
    public var outputFileMap: OutputFileMap
    public var outputFileMapPath: String { "\(name)-output-file-map.json" }
    public var bridgingHeader: URL?
    public var moduleDeps: [String]
    public var importPaths: [String] { moduleDeps.isEmpty ? [] : ["."] }
  }

  public struct ClangTU {
    public var extraArgs: [String]
    public var source: URL
  }
}

public final class TibsResolvedTarget {
  public var name: String
  public var compileUnits: [TibsCompileUnit]
  public var dependencies: [String]

  public init(name: String, compileUnits: [TibsCompileUnit], dependencies: [String]) {
    self.name = name
    self.compileUnits = compileUnits
    self.dependencies = dependencies
  }
}

public struct TibsToolchain {
  public var swiftc: URL
  public var ninja: URL? = nil

  public init(swiftc: URL, ninja: URL? = nil) {
    self.swiftc = swiftc
    self.ninja = ninja
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

/// The JSON clang-compatible compilation database.
///
/// * Note: this only supports the "arguments" form, not "command".
///
/// Example:
///
/// ```
/// [
///   {
///     "directory": "/src",
///     "file": "/src/file.cpp",
///     "arguments": ["clang++", "file.cpp"]
///   }
/// ]
/// ```
///
/// See https://clang.llvm.org/docs/JSONCompilationDatabase.html
public struct JSONCompilationDatabase: Equatable {

  /// A single compilation database command.
  ///
  /// See https://clang.llvm.org/docs/JSONCompilationDatabase.html
  public struct Command: Equatable, Codable {

    /// The working directory for the compilation.
    public var directory: String

    /// The path of the main file for the compilation, which may be relative to `directory`.
    public var file: String

    /// The compile command as a list of strings, with the program name first.
    public var arguments: [String]

    /// The name of the build output, or nil.
    public var output: String? = nil
  }

  var commands: [Command] = []

  init(commands: [Command] = []) {
    self.commands = commands
  }
}

extension JSONCompilationDatabase.Command {

  /// The `URL` for this file. If `filename` is relative and `directory` is
  /// absolute, returns the concatenation. However, if both paths are relative,
  /// it falls back to `filename`, which is more likely to be the identifier
  /// that a caller will be looking for.
  public var url: URL {
    if file.hasPrefix("/") || !directory.hasPrefix("/") {
      return URL(fileURLWithPath: file)
    } else {
      return URL(fileURLWithPath: directory).appendingPathComponent(file, isDirectory: false)
    }
  }
}

extension JSONCompilationDatabase: Codable {
  public init(from decoder: Decoder) throws {
    self.commands = try [Command](from: decoder)
  }
  public func encode(to encoder: Encoder) throws {
    try self.commands.encode(to: encoder)
  }
}

public final class TibsBuilder {

  public private(set) var targets: [TibsResolvedTarget] = []
  public private(set) var targetsByName: [String: TibsResolvedTarget] = [:]
  public private(set) var toolchain: TibsToolchain
  public private(set) var buildRoot: URL

  public var indexstore: URL { buildRoot.appendingPathComponent("index") }

  public enum Error: Swift.Error {
    case duplicateTarget(String)
    case unknownDependency(String, declaredIn: String)
    case buildFailure(Process.TerminationReason, exitCode: Int32)
    case noNinjaBinaryConfigured
  }

  public init(manifest: TibsManifest, sourceRoot: URL, buildRoot: URL, toolchain: TibsToolchain) throws {
    self.toolchain = toolchain
    self.buildRoot = buildRoot

    for targetDesc in manifest.targets {
      let name = targetDesc.name ?? "main"
      let sources = targetDesc.sources.map {
        URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: sourceRoot)
      }
      let bridgingHeader = targetDesc.bridgingHeader.map {
        URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: sourceRoot)
      }

      let swiftFlags = targetDesc.swiftFlags ?? []
      let clangFlags = targetDesc.clangFlags ?? []

      let swiftSources = sources.filter { $0.pathExtension == "swift" }
      let clangSources = sources.filter { $0.pathExtension != "swift" }

      var compileUnits = [TibsCompileUnit]()

      if !swiftSources.isEmpty {
        var outputFileMap = OutputFileMap()
        for source in swiftSources {
          let basename = source.lastPathComponent
          outputFileMap[source.path] = OutputFileMap.Entry(
            swiftmodule: "\(basename).swiftmodule~partial",
            swiftdoc: "\(basename).swiftdoc~partial"
          )
        }

        let cu = TibsCompileUnit.SwiftModule(
          name: name,
          extraArgs: swiftFlags + clangFlags.flatMap { ["-Xcc", $0] },
          sources: swiftSources,
          outputFileMap: outputFileMap,
          bridgingHeader: bridgingHeader,
          moduleDeps: targetDesc.dependencies?.map { "\($0).swiftmodule" } ?? [])

        compileUnits.append(.swiftModule(cu))
      }

      for source in clangSources {
        let cu = TibsCompileUnit.ClangTU(
          extraArgs: clangFlags,
          source: source)
        compileUnits.append(.clangTranslationUnit(cu))
      }

      let target = TibsResolvedTarget(
        name: name,
        compileUnits: compileUnits,
        dependencies: targetDesc.dependencies ?? [])

      targets.append(target)
      if targetsByName.updateValue(target, forKey: name) != nil {
        throw Error.duplicateTarget(name)
      }
    }

    for target in targets {
      for dep in target.dependencies {
        if targetsByName[dep] == nil {
          throw Error.unknownDependency(dep, declaredIn: target.name)
        }
      }
    }
  }

  public var compilationDatabase: JSONCompilationDatabase {
    var commands = [JSONCompilationDatabase.Command]()
    for target in targets {
      for cu in target.compileUnits {
        switch cu {
        case .swiftModule(let module):
          var args = [toolchain.swiftc.path]
          args += module.sources.map { $0.path }
          args += module.importPaths.flatMap { ["-I", $0] }
          args += [
            "-module-name", module.name,
            "-index-store-path", indexstore.path,
            "-index-ignore-system-modules",
            "-output-file-map", module.outputFileMapPath,
            "-emit-module",
            "-emit-module-path", module.emitModulePath,
            "-working-directory", buildRoot.path,
          ]
          args += module.bridgingHeader.map { ["-import-objc-header", $0.path] } ?? []
          args += module.extraArgs

          module.sources.forEach { sourceFile in
            commands.append(JSONCompilationDatabase.Command(
              directory: buildRoot.path,
              file: sourceFile.path,
              arguments: args))
          }

        case .clangTranslationUnit(_):
          break
        }
      }
    }

    return JSONCompilationDatabase(commands: commands)
  }

  public func writeBuildFiles() throws {
    try ninja.write(to: buildRoot.appendingPathComponent("build.ninja"), atomically: false, encoding: .utf8)

    let encoder = JSONEncoder()
    if #available(macOS 10.13, iOS 11.0, watchOS 4.0, tvOS 11.0, *) {
      encoder.outputFormatting = .sortedKeys // stable output
    }

    let compdb = try encoder.encode(compilationDatabase)
    try compdb.write(to: buildRoot.appendingPathComponent("compile_commands.json"))
    for target in targets {
      for cu in target.compileUnits {
        switch cu {
        case .swiftModule(let module):
          let ofm = try encoder.encode(module.outputFileMap)
          try ofm.writeIfChanged(to: buildRoot.appendingPathComponent(module.outputFileMapPath))
        default:
          break
        }
      }
    }
  }

  public func build() throws {

    guard let ninja = toolchain.ninja?.path else {
      throw Error.noNinjaBinaryConfigured
    }

    let p = Process.launchedProcess(launchPath: ninja, arguments: ["-C", buildRoot.path])
    p.waitUntilExit()
    if p.terminationReason != .exit || p.terminationStatus != 0 {
      throw Error.buildFailure(p.terminationReason, exitCode: p.terminationStatus)
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
    for target in targets {
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
        command = \(toolchain.swiftc.path) $in $IMPORT_PATHS -module-name $MODULE_NAME -index-store-path index -index-ignore-system-modules -output-file-map $OUTPUT_FILE_MAP -emit-module -emit-module-path $MODULE_PATH $BRIDGING_HEADER $EXTRA_ARGS
        restat = 1 # Swift doesn't rewrite modules that haven't changed
      """)
  }

  public func writeNinjaSnippet<Output: TextOutputStream>(for target: TibsResolvedTarget, to stream: inout Output) {
    for cu in target.compileUnits {
      switch cu {
      case .swiftModule(let module):
        writeNinjaSnippet(for: module, to: &stream)
      case .clangTranslationUnit(_):
        break
      }
    }
  }

  public func writeNinjaSnippet<Output: TextOutputStream>(for module: TibsCompileUnit.SwiftModule, to stream: inout Output) {
    let outputs = [module.emitModulePath]
    // FIXME: some of these are deleted by the compiler!?
    // outputs += target.outputFileMap.allOutputs

    var deps = module.moduleDeps
    deps.append(module.outputFileMapPath)
    deps.append(toolchain.swiftc.path)
    if let bridgingHeader = module.bridgingHeader {
      deps.append(bridgingHeader.path)
    }

    stream.write("""
      build \(outputs.joined(separator: " ")): \
      swiftc_index \(module.sources.map { $0.path }.joined(separator: " ")) \
      | \(deps.joined(separator: " "))
        MODULE_NAME = \(module.name)
        MODULE_PATH = \(module.emitModulePath)
        IMPORT_PATHS = \(module.importPaths.map { "-I \($0)" }.joined(separator: " "))
        BRIDGING_HEADER = \(module.bridgingHeader.map { "-import-objc-header \($0.path)" } ?? "")
        EXTRA_ARGS = \(module.extraArgs.joined(separator: " "))
        OUTPUT_FILE_MAP = \(module.outputFileMapPath)
      """)
  }
}

extension Data {
  func writeIfChanged(to url: URL, options: Data.WritingOptions = []) throws {
    let prev: Data?
    do {
      prev = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      prev = nil
    }

    if prev != self {
      try write(to: url, options: options)
    }
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
