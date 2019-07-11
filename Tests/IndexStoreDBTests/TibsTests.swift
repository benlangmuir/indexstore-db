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
import ISDBTestSupport
import XCTest

final class TibsTests: XCTestCase {

  func testBasic() throws {
    let ws = try staticTibsTestWorkspace(name: "proj1")
    let index = ws.index

    let getOccs = { index.occurrences(ofUSR: "s:4main1cyyF", roles: [.reference, .definition]) }

    XCTAssertEqual(0, getOccs().count)

    try ws.buildAndIndex()

    let occs = getOccs()
    XCTAssertEqual(2, occs.count)
    guard occs.count == 2 else { return }

    XCTAssertEqual(occs[0].symbol.name, "c()")
    XCTAssertEqual(occs[0].symbol.usr, "s:4main1cyyF")
    if occs[0].roles.contains(.definition) {
      XCTAssertEqual(occs[0].roles, [.definition, .canonical])
      let loc = ws.testLoc("c")
      XCTAssertEqual(occs[0].location, SymbolLocation(path: loc.url.path, isSystem: false, line: loc.line, utf8Column: loc.column))
    } else {
      let loc = ws.testLoc("c:call")
      XCTAssertEqual(occs[0].location, SymbolLocation(path: loc.url.path, isSystem: false, line: loc.line, utf8Column: loc.column))
    }
  }

  func testMixedLangTarget() throws {
    let ws = try staticTibsTestWorkspace(name: "MixedLangTarget")
    try ws.buildAndIndex()
    let index = ws.index

    let cdecl = ws.testLoc("C:decl")
    let cdeclLookup = index.occurrences(atPath: cdecl.url.path, line: cdecl.line, utf8Column: cdecl.column, roles: [.definition, .declaration, .reference])

    XCTAssertEqual(1, cdeclLookup.count)
    guard let cdeclDecl = cdeclLookup.first else { return }
    XCTAssertEqual(cdeclDecl.roles, [.declaration, .canonical])
    XCTAssertEqual(cdeclDecl.symbol.name, "C")
    XCTAssertEqual(cdeclDecl.symbol.usr, "c:objc(cs)C")
    XCTAssertEqual(cdeclDecl.location.path, cdecl.url.path)
    XCTAssertEqual(cdeclDecl.location.line, cdecl.line)
    XCTAssertEqual(cdeclDecl.location.utf8Column, cdecl.column)

    let cdeclOccs = index.occurrences(ofUSR: cdeclDecl.symbol.usr, roles: [.definition, .declaration, .reference])
    XCTAssertEqual(4, cdeclOccs.count)
  }
}
