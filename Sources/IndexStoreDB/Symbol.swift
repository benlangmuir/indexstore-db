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

public enum IndexSymbolKind {
  case unknown
  case module
  case namespace
  case namespaceAlias
  case macro
  case `enum`
  case `struct`
  case `class`
  case `protocol`
  case `extension`
  case union
  case `typealias`
  case function
  case variable
  case field
  case enumConstant
  case instanceMethod
  case classMethod
  case staticMethod
  case instanceProperty
  case classProperty
  case staticProperty
  case constructor
  case destructor
  case conversionFunction
  case parameter
  case using

  case commentTag
}

public final class Symbol {

  let value: indexstoredb_symbol_t

  public lazy var usr: String = String(cString: indexstoredb_symbol_usr(value))
  public lazy var name: String = String(cString: indexstoredb_symbol_name(value))
  public lazy var kind: IndexSymbolKind = IndexSymbolKind(indexstoredb_symbol_kind(value))

  init(_ value: indexstoredb_symbol_t) {
    self.value = value
  }

  deinit {
    indexstoredb_release(value)
  }
}

extension Symbol: Equatable, Comparable {
  public static func ==(a: Symbol, b: Symbol) -> Bool {
    return (a.usr, a.name) == (b.usr, b.name)
  }
  public static func <(a: Symbol, b: Symbol) -> Bool {
    return (a.usr, a.name) < (b.usr, b.name)
  }
}

extension Symbol: CustomStringConvertible {
  public var description: String {
    "\(name) [\(usr)]"
  }
}

extension IndexSymbolKind {
  init(_ cSymbolKind: indexstoredb_symbol_kind_t) {
    switch cSymbolKind {
    case INDEXSTOREDB_SYMBOL_KIND_UNKNOWN:
      self = .unknown
    case INDEXSTOREDB_SYMBOL_KIND_MODULE:
      self = .module
    case INDEXSTOREDB_SYMBOL_KIND_NAMESPACE:
      self = .namespace
    case INDEXSTOREDB_SYMBOL_KIND_NAMESPACEALIAS:
      self = .namespaceAlias
    case INDEXSTOREDB_SYMBOL_KIND_MACRO:
      self = .macro
    case INDEXSTOREDB_SYMBOL_KIND_ENUM:
      self = .enum
    case INDEXSTOREDB_SYMBOL_KIND_STRUCT:
      self = .struct
    case INDEXSTOREDB_SYMBOL_KIND_CLASS:
      self = .class
    case INDEXSTOREDB_SYMBOL_KIND_PROTOCOL:
      self = .protocol
    case INDEXSTOREDB_SYMBOL_KIND_EXTENSION:
      self = .extension
    case INDEXSTOREDB_SYMBOL_KIND_UNION:
      self = .union
    case INDEXSTOREDB_SYMBOL_KIND_TYPEALIAS:
      self = .typealias
    case INDEXSTOREDB_SYMBOL_KIND_FUNCTION:
      self = .function
    case INDEXSTOREDB_SYMBOL_KIND_VARIABLE:
      self = .variable
    case INDEXSTOREDB_SYMBOL_KIND_FIELD:
      self = .field
    case INDEXSTOREDB_SYMBOL_KIND_ENUMCONSTANT:
      self = .enumConstant
    case INDEXSTOREDB_SYMBOL_KIND_INSTANCEMETHOD:
      self = .instanceMethod
    case INDEXSTOREDB_SYMBOL_KIND_CLASSMETHOD:
      self = .classMethod
    case INDEXSTOREDB_SYMBOL_KIND_STATICMETHOD:
      self = .staticMethod
    case INDEXSTOREDB_SYMBOL_KIND_INSTANCEPROPERTY:
      self = .instanceProperty
    case INDEXSTOREDB_SYMBOL_KIND_CLASSPROPERTY:
      self = .classProperty
    case INDEXSTOREDB_SYMBOL_KIND_STATICPROPERTY:
      self = .staticProperty
    case INDEXSTOREDB_SYMBOL_KIND_CONSTRUCTOR:
      self = .constructor
    case INDEXSTOREDB_SYMBOL_KIND_DESTRUCTOR:
      self = .destructor
    case INDEXSTOREDB_SYMBOL_KIND_CONVERSIONFUNCTION:
      self = .conversionFunction
    case INDEXSTOREDB_SYMBOL_KIND_PARAMETER:
      self = .parameter
    case INDEXSTOREDB_SYMBOL_KIND_USING:
      self = .using
    case INDEXSTOREDB_SYMBOL_KIND_COMMENTTAG:
      self = .commentTag
    default:
      self = .unknown
    }
  }
}
