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

import Foundation

extension Data {

  /// Writes the contents of the data to `url` if it is different than the existing contents, or if
  /// the URL does not exist.
  ///
  /// Checking if the contents have changed and writing the new contents are not done atomically,
  /// so there is no guarantee that there are no spurious writes if this API is used concurrently.
  func writeIfChanged(to url: URL, options: Data.WritingOptions = []) throws {
    let prev: Data?
    do {
      prev = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      prev = nil
    }

    if prev != self {
      try write(to: url, options: options)
    }
  }
}
