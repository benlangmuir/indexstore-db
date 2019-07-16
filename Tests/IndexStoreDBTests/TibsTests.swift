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
    guard let ws = try staticTibsTestWorkspace(name: "proj1") else { return }
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
    guard let ws = try staticTibsTestWorkspace(name: "MixedLangTarget") else { return }
    try ws.buildAndIndex()
    let index = ws.index

  #if os(macOS)
    let cdeclOccs = index.occurrences(ofUSR: "c:objc(cs)C", roles: [.definition, .declaration, .reference])
    checkOccurrences(cdeclOccs, usr: "c:objc(cs)C", locations: [
      ws.testLoc("C:decl"),
      ws.testLoc("C:def"),
      ws.testLoc("C:ref:swift"),
      ws.testLoc("C:ref:e.mm"),
    ])

    let cmethodOccs = index.occurrences(ofUSR: "c:objc(cs)C(im)method", roles: [.definition, .declaration, .reference])
    checkOccurrences(cmethodOccs, usr: "c:objc(cs)C(im)method", locations: [
      ws.testLoc("C.method:call:swift"),
      ws.testLoc("C.method:decl"),
      ws.testLoc("C.method:def"),
      ws.testLoc("C.method:call:e.mm"),
    ])
  #endif

    let dOccs = index.occurrences(ofUSR: "c:@S@D", roles: [.definition, .declaration, .reference])
    checkOccurrences(dOccs, usr: "c:@S@D", locations: [
      ws.testLoc("D:def"),
      ws.testLoc("D:ref"),
      ws.testLoc("D:ref:e.mm"),
    ])

    let bridgingHeaderOccs = index.occurrences(ofUSR: "c:@F@bridgingHeader", roles: [.definition, .declaration, .reference])
    checkOccurrences(bridgingHeaderOccs, usr: "c:@F@bridgingHeader", locations: [
      ws.testLoc("bridgingHeader:call"),
      ws.testLoc("bridgingHeader:decl"),
    ])
  }

  func testSwiftModules() throws {
    guard let ws = try staticTibsTestWorkspace(name: "SwiftModules") else { return }
    try ws.buildAndIndex()

    let occs = ws.index.occurrences(ofUSR: "s:1A3aaayyF", roles: [.definition, .declaration, .reference])
    checkOccurrences(occs, usr: "s:1A3aaayyF", locations: [
      ws.testLoc("aaa:def"),
      ws.testLoc("aaa:call"),
      ws.testLoc("aaa:call:c"),
    ])
  }
}

func checkOccurrences(
  _ occurs: [SymbolOccurrence],
  usr: String,
  locations: [TestLoc],
  file: StaticString = #file,
  line: UInt = #line)
{
  let occurs = occurs.sorted()
  let locations = locations.sorted()

  var ai = occurs.startIndex
  let aend = occurs.endIndex
  var ei = locations.startIndex
  let eend = locations.endIndex

  func compare(actual: SymbolOccurrence, expected: TestLoc) -> ComparisonResult {
    let loc = TestLoc(actual.location)
    if loc == expected { return .orderedSame }
    if loc < expected { return .orderedAscending }
    return .orderedDescending
  }

  while ai != aend && ei != eend {
    XCTAssertEqual(occurs[ai].symbol.usr, usr, file: file, line: line)

    switch compare(actual: occurs[ai], expected: locations[ei]) {
    case .orderedSame:
      occurs.formIndex(after: &ai)
      locations.formIndex(after: &ei)
    case .orderedAscending:
      XCTFail("unexpected symbol occurrence \(occurs[ai])", file: file, line: line)
      occurs.formIndex(after: &ai)
    case .orderedDescending:
      XCTFail("missing expected symbol occurrence at \(locations[ei])", file: file, line: line)
      locations.formIndex(after: &ei)
    }
  }

  while ai != aend {
    XCTAssertEqual(occurs[ai].symbol.usr, usr, file: file, line: line)
    XCTFail("unexpected symbol occurrence \(occurs[ai])", file: file, line: line)
    occurs.formIndex(after: &ai)
  }

  while ei != eend {
    XCTFail("missing expected symbol occurrence at \(locations[ei])", file: file, line: line)
    locations.formIndex(after: &ei)
  }
}
