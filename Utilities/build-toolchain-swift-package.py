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

LIB_SUFFIX = 'dylib' if platform.system() == 'Darwin' else 'so'

verbose = False

def main():
  parser = argparse.ArgumentParser(description='Build a SwiftPM package as part of the Swift toolchain build.')
  parser.add_argument('-v', '--verbose', action='store_true', help='use verbose output')

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
  toolchain_group.add_argument('--swiftc', dest='swiftc_path',
      help='path to the swift compiler',
      metavar='PATH')
  toolchain_group.add_argument('--swift-build', dest='swift_build_path',
      help='path to the swift-build exectuable',
      metavar='PATH')
  toolchain_group.add_argument('--swift-build-tool', dest='swift_build_tool_path',
      help='path to the swift-build-tool exectuable',
      metavar='PATH')
  toolchain_group.add_argument('--swift-test', dest='swift_test_path',
      help='path to the swift-test exectuable',
      metavar='PATH')
  toolchain_group.add_argument('--foundation', dest='foundation_path',
      help='path to Foundation build directory')
  toolchain_group.add_argument('--xctest', dest='xctest_path',
      help='path to XCTest build directory')
  toolchain_group.add_argument('--libdispatch-build-dir',
      help='path to the libdispatch build directory')
  toolchain_group.add_argument('--libdispatch-source-dir',
      help='path to the libdispatch source directory')

  args = parser.parse_args()

  global verbose
  verbose = args.verbose

  build_path = os.path.abspath(args.build_path)
  toolchain_root = os.path.join(build_path, 'fake_toolchain')

  makedirs_force(toolchain_root)

  make_fake_toolchain(toolchain_root, args)

  # build, test

def make_fake_toolchain(root, args):
  shutil.rmtree(root)

  bin_path = os.path.join(root, 'usr', 'bin')
  lib_path = os.path.join(root, 'usr', 'lib')
  lib_swift_path = os.path.join(lib_path, 'swift')
  makedirs_force(bin_path)
  makedirs_force(lib_swift_path)

  def maybe_copy_or_symlink(target, link_name):
    if target and os.path.exists(target):
      copy_or_symlink(target, link_name)
    else:
      print('Skip {}'.format(target))

  if args.swiftc_path:
    # Needs to be a hard link, because the resource directory is resolved
    # relative to the binary's real path.
    copy_or_hardlink(args.swiftc_path, os.path.join(bin_path, 'swift'))
    symlink_force('swift', os.path.join(bin_path, 'swiftc'))
    target_bin = os.path.dirname(args.swiftc_path)
    target_lib = os.path.normpath(os.path.join(target_bin, '..',  'lib'))

    copy_or_symlink_recursive(os.path.join(target_lib, 'swift'), lib_swift_path)
    maybe_copy_or_symlink(os.path.join(target_lib, 'sourcekitd.framework'), lib_path)
    maybe_copy_or_symlink(os.path.join(target_lib, 'libsourcekitdInProc.{}'.format(LIB_SUFFIX)), lib_path)

  maybe_copy_or_symlink(args.swift_build_path, os.path.join(bin_path, 'swift-build'))
  maybe_copy_or_symlink(args.swift_test_path, os.path.join(bin_path, 'swift-test'))

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

def copy_or_hardlink(target, link_name):
  link_force(target, link_name)

def symlink_force(target, link_name):
  if verbose:
    print('Symlink {} -> {}'.format(link_name, target))

  if os.path.isdir(link_name):
    link_name = os.path.join(link_name, os.path.basename(target))
  try:
    os.symlink(target, link_name)
  except OSError as e:
    if e.errno == errno.EEXIST:
      os.remove(link_name)
      os.symlink(target, link_name)
    else:
      raise e

def link_force(target, link_name):
  if verbose:
    print('Hardlink {} -> {}'.format(link_name, target))

  if os.path.isdir(link_name):
    link_name = os.path.join(link_name, os.path.basename(target))
  try:
    os.link(target, link_name)
  except OSError as e:
    if e.errno == errno.EEXIST:
      os.remove(link_name)
      os.link(target, link_name)
    else:
      raise e

def makedirs_force(path):
  try:
    os.makedirs(path)
  except OSError as e:
    if e.errno != errno.EEXIST:
      raise e

if __name__ == '__main__':
  main()
