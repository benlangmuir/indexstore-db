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

public final class SymbolOccurrence {

  let value: indexstoredb_symbol_occurrence_t

  public lazy var symbol: Symbol = Symbol(indexstoredb_symbol_occurrence_symbol(value))
  public lazy var roles: SymbolRole = SymbolRole(rawValue: indexstoredb_symbol_occurrence_roles(value))
  public lazy var location: SymbolLocation = SymbolLocation(indexstoredb_symbol_occurrence_location(value))
  public lazy var relations: [SymbolRelation] = getRelations()

  init(_ value: indexstoredb_symbol_occurrence_t) {
    self.value = value
  }

  deinit {
    indexstoredb_release(value)
  }

  private func getRelations() -> [SymbolRelation] {
    var relations: [SymbolRelation] = []
    forEachRelation{relation in
      relations.append(relation)
      return true
    }
    return relations
  }

  @discardableResult public func forEachRelation(
    body: @escaping (SymbolRelation) -> Bool
  ) -> Bool {
    return indexstoredb_symbol_occurrence_relations(value){ relation in
      body(SymbolRelation(relation))
    }
  }
}

extension SymbolOccurrence: Equatable, Comparable {
  public static func ==(a: SymbolOccurrence, b: SymbolOccurrence) -> Bool {
    return (a.symbol, a.roles, a.location) == (b.symbol, b.roles, b.location)
  }
  public static func <(a: SymbolOccurrence, b: SymbolOccurrence) -> Bool {
    return (a.location, a.roles, a.symbol) < (b.location, b.roles, b.symbol)
  }
}

extension SymbolOccurrence: CustomStringConvertible {
  public var description: String {
    "\(symbol) @\(location) roles:\(roles)"
  }
}

public final class SymbolRelation {
  let value: indexstoredb_symbol_relation_t

  public lazy var roles: SymbolRole = SymbolRole(rawValue: indexstoredb_symbol_relation_get_roles(value))
  public lazy var symbol: Symbol = Symbol(indexstoredb_symbol_relation_get_symbol(value))

  public init(_ value: indexstoredb_symbol_relation_t) {
    self.value = value
  }
}
