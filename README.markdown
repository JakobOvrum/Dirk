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

 * `source` - the Dirk source package.
 * `libev` - the Deimos bindings for libev.
 * `lib` - Dirk library files (when built).
 * `extlib` - libev object files; see [extlib/README.md](https://github.com/JakobOvrum/Dirk/blob/master/extlib/README.md) for details.

[Documentation](https://jakobovrum.github.io/Dirk/)
============================================
You can find automatically generated documentation on the [gh-pages](https://github.com/JakobOvrum/Dirk/tree/gh-pages) branch, or you can [browse it online](https://jakobovrum.github.io/Dirk/).

Usage
============================================
Dirk works with [dub](http://code.dlang.org/) out of the box.
See [Dirk on the package repository](http://code.dlang.org/packages/dirk) for details.

License
============================================
Dirk is licensed under the terms of the MIT license (see the [LICENSE file](http://github.com/JakobOvrum/Dirk/blob/master/LICENSE) for details).
