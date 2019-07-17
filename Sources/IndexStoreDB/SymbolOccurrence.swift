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

// FIXME: remove
public typealias SymbolRelation = SymbolOccurrence.Relation

public struct SymbolOccurrence: Equatable {

  public struct Relation: Equatable {
    public var symbol: Symbol
    public var roles: SymbolRole

    public init(symbol: Symbol, roles: SymbolRole) {
      self.symbol = symbol
      self.roles = roles
    }
  }

  public var symbol: Symbol
  public var location: SymbolLocation
  public var roles: SymbolRole
  public var relations: [Relation]

  init(symbol: Symbol, location: SymbolLocation, roles: SymbolRole, relations: [Relation] = []) {
    self.symbol = symbol
    self.location = location
    self.roles = roles
    self.relations = relations
  }
}

extension SymbolOccurrence: Comparable {
  public static func <(a: SymbolOccurrence, b: SymbolOccurrence) -> Bool {
    // FIXME: incorporate relations
    return (a.location, a.roles, a.symbol) < (b.location, b.roles, b.symbol)
  }
}

extension SymbolOccurrence.Relation: Comparable {
  public static func <(a: SymbolOccurrence.Relation, b: SymbolOccurrence.Relation) -> Bool {
    (a.roles, a.symbol) < (b.roles, b.symbol)
  }
}

extension SymbolOccurrence: CustomStringConvertible {
  public var description: String {
    // FIXME: incorporate relations
    "\(symbol) @\(location) roles:\(roles)"
  }
}

// MARK: CIndexStoreDB conversions

extension SymbolOccurrence {

  /// Note: `value` is expected to be passed +1.
  init(_ value: indexstoredb_symbol_occurrence_t) {
    var relations: [Relation] = []
    indexstoredb_symbol_occurrence_relations(value) { relation in
      relations.append(Relation(relation))
      return true
    }

    self.init(
      symbol: Symbol(indexstoredb_symbol_occurrence_symbol(value)),
      location: SymbolLocation(indexstoredb_symbol_occurrence_location(value)),
      roles: SymbolRole(rawValue: indexstoredb_symbol_occurrence_roles(value)),
      relations: relations)

    // FIXME: remove unnecessary refcounting of occurrences.
    indexstoredb_release(value)
  }
}

extension SymbolOccurrence.Relation {
  public init(_ value: indexstoredb_symbol_relation_t) {
    self.init(
      symbol: Symbol(indexstoredb_symbol_relation_get_symbol(value)),
      roles: SymbolRole(rawValue: indexstoredb_symbol_relation_get_roles(value)))
  }
}
