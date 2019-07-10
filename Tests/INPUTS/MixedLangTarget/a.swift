func test(c: C) {
  c.method()
  bridgingHeader()
}

@_cdecl("fo") public func foo() { }
