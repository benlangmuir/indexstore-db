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

    let usr = "s:4main1cyyF"
    let getOccs = { index.occurrences(ofUSR: usr, roles: [.reference, .definition]) }

    XCTAssertEqual(0, getOccs().count)

    try ws.buildAndIndex()

    let csym = Symbol(usr: usr, name: "c()", kind: .function)
    let asym = Symbol(usr: "s:4main1ayyF", name: "a()", kind: .function)

    let ccanon = SymbolOccurrence(
      symbol: csym,
      location: SymbolLocation(ws.testLoc("c")),
      roles: [.definition, .canonical],
      relations: [])

    let ccall = SymbolOccurrence(
      symbol: csym,
      location: SymbolLocation(ws.testLoc("c:call")),
      roles: [.reference, .call, .calledBy, .containedBy],
      relations: [
        .init(symbol: asym, roles: [.calledBy, .containedBy])
    ])

    checkOccurrences(getOccs(), expected: [
      ccanon,
      ccall,
    ])

    checkOccurrences(index.canonicalOccurrences(ofName: "c()"), expected: [
      ccanon,
    ])

    checkOccurrences(index.canonicalOccurrences(ofName: "c"), expected: [])

    checkOccurrences(index.canonicalOccurrences(containing: "c",
      anchorStart: true, anchorEnd: false, subsequence: false,
      ignoreCase: false), expected: [ccanon])

    checkOccurrences(index.canonicalOccurrences(containing: "c",
      anchorStart: true, anchorEnd: true, subsequence: false,
      ignoreCase: false), expected: [])

    checkOccurrences(index.canonicalOccurrences(containing: "C",
      anchorStart: true, anchorEnd: false, subsequence: false,
      ignoreCase: true), expected: [ccanon])

    checkOccurrences(index.canonicalOccurrences(containing: "C",
      anchorStart: true, anchorEnd: false, subsequence: false,
      ignoreCase: false), expected: [])

    checkOccurrences(index.occurrences(relatedToUSR: "s:4main1ayyF", roles: .calledBy), expected: [
      ccall,
      SymbolOccurrence(
        symbol: Symbol(usr: "s:4main1byyF", name: "b()", kind: .function),
        location: SymbolLocation(ws.testLoc("b:call")),
        roles: [.reference, .call, .calledBy, .containedBy],
        relations: [
          .init(symbol: asym, roles: [.calledBy, .containedBy])
      ])
    ])
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

  func testEditsSimple() throws {
    guard let ws = try mutableTibsTestWorkspace(name: "proj1") else { return }
    try ws.buildAndIndex()

    let usr = "s:4main1cyyF"
    let roles: SymbolRole = [.reference, .definition, .declaration]

    checkOccurrences(ws.index.occurrences(ofUSR: usr, roles: roles), usr: usr, locations: [
      ws.testLoc("c"),
      ws.testLoc("c:call"),
    ])

    try ws.edit(rebuild: true) { editor, files in
      let url = ws.testLoc("c:call").url
      let new = try files.get(url).appending("""

        func anotherOne() {
          /*c:anotherOne*/c()
        }
        """)

      editor.write(new, to: url)
    }

    checkOccurrences(ws.index.occurrences(ofUSR: usr, roles: roles), usr: usr, locations: [
      ws.testLoc("c"),
      ws.testLoc("c:call"),
      ws.testLoc("c:anotherOne"),
    ])

    XCTAssertNotEqual(ws.testLoc("c").url, ws.testLoc("a:def").url)

    try ws.edit(rebuild: true) { editor, files in
      editor.write("", to: ws.testLoc("c").url)
      let new = try files.get(ws.testLoc("a:def").url).appending("\nfunc /*c*/c() -> Int { 0 }")
      editor.write(new, to: ws.testLoc("a:def").url)
    }

    XCTAssertEqual(ws.testLoc("c").url, ws.testLoc("a:def").url)

    checkOccurrences(ws.index.occurrences(ofUSR: usr, roles: roles), usr: usr, locations: [])

    let newUSR = "s:4main1cSiyF"
    checkOccurrences(ws.index.occurrences(ofUSR: newUSR, roles: roles), usr: newUSR, locations: [
      ws.testLoc("c"),
      ws.testLoc("c:call"),
      ws.testLoc("c:anotherOne"),
    ])
  }
}

func checkOccurrences(
  _ occurs: [SymbolOccurrence],
  expected: [SymbolOccurrence],
  ignoreRelations: Bool = false,
  file: StaticString = #file,
  line: UInt = #line)
{
  var expected: [SymbolOccurrence] = expected
  var actual: [SymbolOccurrence] = occurs

  if ignoreRelations {
    for i in expected.indices {
      expected[i].relations = []
    }
    for i in actual.indices {
      actual[i].relations = []
    }
  }

  expected.sort()
  actual.sort()

  var ai = actual.startIndex
  let aend = actual.endIndex
  var ei = expected.startIndex
  let eend = expected.endIndex

  func compare(_ a: SymbolOccurrence, _ b: SymbolOccurrence) -> ComparisonResult {
    if a == b { return .orderedSame }
    if a < b { return .orderedAscending }
    return .orderedDescending
  }

  while ai != aend && ei != eend {
    switch compare(actual[ai], expected[ei]) {
    case .orderedSame:
      actual.formIndex(after: &ai)
      expected.formIndex(after: &ei)
    case .orderedAscending:
      XCTFail("unexpected symbol occurrence \(actual[ai])", file: file, line: line)
      actual.formIndex(after: &ai)
    case .orderedDescending:
      XCTFail("missing expected symbol occurrence \(expected[ei])", file: file, line: line)
      expected.formIndex(after: &ei)
    }
  }

  while ai != aend {
    XCTFail("unexpected symbol occurrence \(actual[ai])", file: file, line: line)
    actual.formIndex(after: &ai)
  }

  while ei != eend {
    XCTFail("missing expected symbol occurrence \(expected[ei])", file: file, line: line)
    expected.formIndex(after: &ei)
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
