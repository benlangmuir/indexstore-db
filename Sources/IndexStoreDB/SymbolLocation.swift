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

import CIndexStoreDB

public struct SymbolLocation: Equatable {
  public var path: String
  public var isSystem: Bool
  public var line: Int
  public var utf8Column: Int

  public init(path: String, isSystem: Bool = false, line: Int, utf8Column: Int) {
    self.path = path
    self.isSystem = isSystem
    self.line = line
    self.utf8Column = utf8Column
  }

  public init(_ loc: indexstoredb_symbol_location_t) {
    path = String(cString: indexstoredb_symbol_location_path(loc))
    isSystem = indexstoredb_symbol_location_is_system(loc)
    line = Int(indexstoredb_symbol_location_line(loc))
    utf8Column = Int(indexstoredb_symbol_location_column_utf8(loc))
  }
}

extension SymbolLocation: Comparable {
  public static func <(a: SymbolLocation, b: SymbolLocation) -> Bool {
    return (a.path, a.line, a.utf8Column, a.isSystem ? 1 : 0)
      < (b.path, b.line, b.utf8Column, b.isSystem ? 1 : 0)
  }
}

extension SymbolLocation: CustomStringConvertible {
  public var description: String {
    "\(path):\(line):\(utf8Column)\(isSystem ? " [system]" : "")"
  }
}
