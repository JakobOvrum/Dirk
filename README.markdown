Dirk [![dub](https://img.shields.io/dub/v/dirk.svg)](http://code.dlang.org/packages/dirk) [![Build Status](https://img.shields.io/travis/JakobOvrum/Dirk.svg)](https://travis-ci.org/JakobOvrum/Dirk)
============================================
Dirk is an IRC client library for the D programming language.

It aims for a complete and correct implementation of the
IRC client protocol ([RFC 2812](https://tools.ietf.org/html/rfc2812))
and related protocols (CTCP and DCC) with a safe interface.

Dirk aims to be as efficient as possible (in terms of both CPU and memory) to cater to the requirements
of any imaginable use of IRC.

For an IRC bot framework built on Dirk, see [Diggler](https://github.com/JakobOvrum/Diggler).

Dirk depends on [libev](http://software.schmorp.de/pkg/libev.html) for the
event loop.

**Please report bugs and requests to the [issue tracker](https://github.com/JakobOvrum/Dirk/issues). Thanks!**

Directory Structure
============================================

 * `irc` - the Dirk source package.
 * `visuald` - [VisualD](http://www.dsource.org/projects/visuald) project files.
 * `test` - unittest executable (when built).
 * `lib` - Dirk library files (when built).
 * `extlib/ev.obj` - libev object file in OMF format for convenience on Windows.
 * `ssl` - utility package for lazily loading OpenSSL at runtime for SSL/TLS connections.

[Documentation](http://jakobovrum.github.com/Dirk/)
============================================
You can find automatically generated documentation on the [gh-pages](https://github.com/JakobOvrum/Dirk/tree/gh-pages) branch, or you can [browse it online](http://jakobovrum.github.com/Dirk/).

Usage
============================================
Once built, add the top directory (with the `irc` sub-directory) and the `libev` directory
as include directories when compiling the user program, and
link to `lib/dirk` (release build) or `lib/dirk-d` (debug build).

Example:

    dmd main.d -IDirk -IDirk/libev -L-lev Dirk/lib/dirk.a

(Note: on Windows, the file extension for the static libraries may be `.lib` in many cases)

Building on Windows
============================================
The included [VisualD](http://www.dsource.org/projects/visuald) project files (see the `visuald` sub-directory)
can be used to build the library files on Windows.

Building in General
============================================
Use the included [makefile](http://github.com/JakobOvrum/Dirk/blob/master/Makefile).

License
============================================
Dirk is licensed under the terms of the MIT license (see the [LICENSE file](http://github.com/JakobOvrum/Dirk/blob/master/LICENSE) for details).
