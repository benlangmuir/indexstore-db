func test(c: C) {
  c.method()
  bridgingHeader()
}

@_cdecl("foo") public func foo() { }
