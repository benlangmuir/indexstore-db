#!/usr/bin/env python

# This source file is part of the Swift.org open source project
#
# Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See https://swift.org/LICENSE.txt for license information
# See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

from __future__ import print_function

import argparse
import errno
import os
import platform
import shutil
import subprocess
import sys

LIB_SUFFIX = 'dylib' if platform.system() == 'Darwin' else 'so'

verbose = False

def main():
  parser = argparse.ArgumentParser(description='Build a SwiftPM package as part of the Swift toolchain build.')
  parser.add_argument('-v', '--verbose', action='store_true', help='use verbose output')
  parser.add_argument('build_actions', help="extra actions to perform (test)", nargs="*", default=[])

  swiftpm_group = parser.add_argument_group('swift package options')
  swiftpm_group.add_argument('--build-path',
      help='create build products at PATH [%(default)s]',
      default='.build', metavar='PATH')
  swiftpm_group.add_argument('--package-path',
      help='use the sources from PATH [%(default)s]',
      default='.', metavar='PATH')
  swiftpm_group.add_argument('--configuration', '-c',
      help='build with configuration (debug|release) [%(default)s]',
      default='debug', metavar='CONFIG')

  toolchain_group = parser.add_argument_group('toolchain options')
  toolchain_group.add_argument('--swift', dest='swift_path',
      help='path to the swift executable',
      metavar='PATH', required=True)
  toolchain_group.add_argument('--swift-build', dest='swift_build_path',
      help='path to the swift-build exectuable',
      metavar='PATH')
  toolchain_group.add_argument('--swiftpm-bootstrap', dest='swiftpm_bootstrap_path',
      help='path to the swiftpm .bootstrap directory',
      metavar='PATH')
  toolchain_group.add_argument('--swift-build-tool', dest='swift_build_tool_path',
      help='path to the swift-build-tool exectuable',
      metavar='PATH')
  toolchain_group.add_argument('--foundation-build-dir',
      help='path to Foundation build directory')
  toolchain_group.add_argument('--foundation-source-dir',
      help='path to Foundation source directory')
  toolchain_group.add_argument('--xctest', dest='xctest_path',
      help='path to XCTest build directory')
  toolchain_group.add_argument('--libdispatch-build-dir',
      help='path to the libdispatch build directory')
  toolchain_group.add_argument('--libdispatch-source-dir',
      help='path to the libdispatch source directory')

  args = parser.parse_args()

  # Validate the build actions.
  for action in args.build_actions:
      if action not in ('test'):
          raise SystemExit("unknown build action: {}".format(action))

  global verbose
  verbose = args.verbose

  build_path = os.path.abspath(args.build_path)
  toolchain_root = os.path.join(build_path, 'fake_toolchain')

  make_fake_toolchain(toolchain_root, args)

  swift = os.path.join(toolchain_root, 'usr', 'bin', 'swift')
  if 'test' in args.build_actions:
    swiftpm_cmd(swift, 'test', args, toolchain_root)
  else:
    swiftpm_cmd(swift, 'build', args, toolchain_root)

def swiftpm_cmd(swift, verb, args, toolchain_root):
  cmd = [swift, verb]

  if platform.system() != 'Darwin':
    cmd += ['-Xcxx', '-I', '-Xcxx', os.path.join(toolchain_root, 'usr', 'lib', 'swift')]

  if verbose:
    print(' '.join(cmd))
  subprocess.check_call(cmd, stderr=subprocess.STDOUT)

def make_fake_toolchain(root, args):
  if os.path.exists(root):
    shutil.rmtree(root)

  bin_path = os.path.join(root, 'usr', 'bin')
  lib_path = os.path.join(root, 'usr', 'lib')
  lib_swift_path = os.path.join(lib_path, 'swift')
  if platform.system() == 'Darwin':
    lib_swift_host_path = os.path.join(lib_swift_path, 'macosx')
  elif platform.system() == 'Linux':
    lib_swift_host_path = os.path.join(lib_swift_path, 'linux')
  else:
    print('Unknown host platform')
    sys.exit(1)
  # FIXME: hardcoded arch
  module_path = os.path.join(lib_swift_host_path, 'x86_64')

  makedirs_force(bin_path)
  makedirs_force(module_path)

  def maybe_copy_or_symlink(target, link_name):
    if target and os.path.exists(target):
      copy_or_symlink(target, link_name)
    elif target:
      print('Skip {}'.format(target))

  # swift cannot be a symlink, because the resource directory is resolved
  # relative to the binary's real path.
  clonefile(args.swift_path, os.path.join(bin_path, 'swift'))
  symlink_force('swift', os.path.join(bin_path, 'swiftc'))
  target_bin = os.path.dirname(args.swift_path)
  target_lib = os.path.normpath(os.path.join(target_bin, '..',  'lib'))

  copy_or_symlink_recursive(os.path.join(target_lib, 'swift'), lib_swift_path)
  maybe_copy_or_symlink(os.path.join(target_lib, 'sourcekitd.framework'), lib_path)
  maybe_copy_or_symlink(os.path.join(target_lib, 'libsourcekitdInProc.{}'.format(LIB_SUFFIX)), lib_path)

  maybe_copy_or_symlink(args.swift_build_tool_path, os.path.join(bin_path, 'swift-build-tool'))

  if args.swift_build_path:
    maybe_copy_or_symlink(args.swift_build_path, os.path.join(bin_path, 'swift-build'))
    dir_path = os.path.join(os.path.dirname(args.swift_build_path))
    maybe_copy_or_symlink(os.path.join(dir_path, 'swift-test'), os.path.join(bin_path, 'swift-test'))

  if args.swiftpm_bootstrap_path:
    maybe_copy_or_symlink(os.path.join(args.swiftpm_bootstrap_path, 'lib', 'swift', 'pm'), lib_swift_path)

  if args.libdispatch_source_dir:
    maybe_copy_or_symlink(os.path.join(args.libdispatch_source_dir, 'dispatch'), lib_swift_path)
    maybe_copy_or_symlink(os.path.join(args.libdispatch_source_dir, 'os'), lib_swift_path)

  if args.libdispatch_build_dir:
    maybe_copy_or_symlink(os.path.join(args.libdispatch_build_dir, 'libBlocksRuntime.{}'.format(LIB_SUFFIX)), lib_swift_host_path)
    maybe_copy_or_symlink(os.path.join(args.libdispatch_build_dir, 'src', 'libdispatch.{}'.format(LIB_SUFFIX)), lib_swift_host_path)
    maybe_copy_or_symlink(os.path.join(args.libdispatch_build_dir, 'src', 'libswiftDispatch.{}'.format(LIB_SUFFIX)), lib_swift_host_path)
    maybe_copy_or_symlink(os.path.join(args.libdispatch_build_dir, 'src', 'swift', 'Dispatch.swiftmodule'), module_path)
    maybe_copy_or_symlink(os.path.join(args.libdispatch_build_dir, 'src', 'swift', 'Dispatch.swiftdoc'), module_path)

  if args.foundation_build_dir:
    maybe_copy_or_symlink(os.path.join(args.foundation_build_dir, 'libFoundation.{}'.format(LIB_SUFFIX)), lib_swift_host_path)
    maybe_copy_or_symlink(os.path.join(args.foundation_build_dir, 'swift', 'Foundation.swiftmodule'), module_path)
    maybe_copy_or_symlink(os.path.join(args.foundation_build_dir, 'swift', 'Foundation.swiftdoc'), module_path)

    cf_in_path = os.path.join(args.foundation_build_dir, 'CoreFoundation-prefix', 'System', 'Library', 'Frameworks', 'CoreFoundation.framework')
    cf_out_path = os.path.join(lib_swift_path, 'CoreFoundation')
    makedirs_force(cf_out_path)
    copy_or_symlink_recursive(os.path.join(cf_in_path, 'Headers'), cf_out_path)
    maybe_copy_or_symlink(os.path.join(args.foundation_source_dir, 'CoreFoundation', 'Base.subproj', 'module.map'), os.path.join(lib_swift_path, 'CoreFoundation'))

  if args.xctest_path:
    maybe_copy_or_symlink(os.path.join(args.xctest_path, 'libXCTest.{}'.format(LIB_SUFFIX)), lib_swift_host_path)
    maybe_copy_or_symlink(os.path.join(args.xctest_path, 'swift', 'XCTest.swiftmodule'), module_path)
    maybe_copy_or_symlink(os.path.join(args.xctest_path, 'swift', 'XCTest.swiftdoc'), module_path)

def copy_or_symlink_recursive(target_dir, link_dir):
  for root, dirs, files in os.walk(target_dir):
    assert(os.path.commonprefix([target_dir, root]) == target_dir)
    link_root = os.path.join(link_dir, os.path.relpath(root, target_dir))
    makedirs_force(link_root)
    for file in files:
      copy_or_symlink(os.path.join(root, file), link_root)
    for dir in dirs:
      if os.path.islink(os.path.join(root, dir)):
        copy_or_symlink(os.path.join(root, dir), link_root)

def copy_or_symlink(target, link_name):
  symlink_force(target, link_name)

def symlink_force(target, link_name):
  if os.path.isdir(link_name):
    link_name = os.path.join(link_name, os.path.basename(target))

  if verbose:
    print('Symlink {} -> {}'.format(link_name, target))

  try:
    os.symlink(target, link_name)
  except OSError as e:
    if e.errno == errno.EEXIST:
      os.remove(link_name)
      os.symlink(target, link_name)
    else:
      raise e

def clonefile(source, dest):
  if verbose:
    print('Copy {} to {}'.format(source, dest))

  shutil.copy2(source, dest)

def makedirs_force(path):
  try:
    os.makedirs(path)
  except OSError as e:
    if e.errno != errno.EEXIST:
      raise e

if __name__ == '__main__':
  main()
