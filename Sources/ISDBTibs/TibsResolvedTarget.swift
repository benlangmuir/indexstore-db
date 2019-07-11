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

import struct Foundation.URL

/// A tibs target with all its compilation units resolved and ready to build.
///
/// The resolved target contains all the information needed to index/build a single target in a tibs
/// build graph, assuming its dependencies have been built. It should be possible to generate a
/// command line invocation or ninja build description of each compilation unit in the resolved
/// target without additional information.
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

public enum TibsCompileUnit {
  case swiftModule(SwiftModule)
  case clangTranslationUnit(ClangTU)

  public struct SwiftModule {
    public var name: String
    public var extraArgs: [String]
    public var sources: [URL]
    public var emitModulePath: String
    public var emitHeaderPath: String?
    public var outputFileMap: OutputFileMap
    public var outputFileMapPath: String { "\(name)-output-file-map.json" }
    public var bridgingHeader: URL?
    public var moduleDeps: [String]
    public var importPaths: [String] { moduleDeps.isEmpty ? [] : ["."] }
  }

  public struct ClangTU {
    public var extraArgs: [String]
    public var source: URL
    public var importPaths: [String]
    public var generatedHeaderDep: String?
    public var outputPath: String
  }
}
