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

/// The set of commandline tools used to build a tibs project.
public struct TibsToolchain {
  public var swiftc: URL
  public var clang: URL
  public var tibs: URL
  public var ninja: URL? = nil

  public init(swiftc: URL, clang: URL, tibs: URL, ninja: URL? = nil) {
    self.swiftc = swiftc
    self.clang = clang
    self.tibs = tibs
    self.ninja = ninja
  }
}
