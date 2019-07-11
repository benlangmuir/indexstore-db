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

/// A swiftc-compatible output file map, describing the set of auxiliary output files for a Swift
/// compilation.
public struct OutputFileMap {

  /// A single entry in the OutputFileMap.
  public struct Entry: Hashable, Codable {
    public var swiftmodule: String?
    public var swiftdoc: String?
    public var dependencies: String?
  }

  public var value: [String: Entry] = [:]

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
