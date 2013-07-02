Dirk
============================================
Dirk is an IRC library for the D programming language.

It aims for a complete and correct implementation of the IRC protocol and related protocols
with a safe interface.

It does not aim to be a bot framework; those should be built on top of Dirk as separate projects.

Dirk aims to be as efficient as possible (in terms of both CPU and memory) to cater to the requirements
of any possible user of IRC in D.

**Please report bugs and requests to the [issue tracker](https://github.com/JakobOvrum/Dirk/issues). Thanks!**

Directory Structure
============================================

 * `irc` - the Dirk package.
 * `visuald` - [VisualD](http://www.dsource.org/projects/visuald) project files.
 * `test` - unittest executable (when built).
 * `lib` - Dirk library files (when built).

[Documentation](http://jakobovrum.github.com/Dirk/)
============================================
You can find automatically generated documentation on the [gh-pages](https://github.com/JakobOvrum/Dirk/tree/gh-pages) branch, or you can [browse it online](http://jakobovrum.github.com/Dirk/).

Usage
============================================
Once built, add the top directory (with the `irc` sub-directory) and the `libev` directory
as include directories when compiling the user program, and
link to `lib/dirk` (release build) or `lib/dirk-d` (debug build).

Example:

    dmd main.d -IDirk -IDirk/libev Dirk/lib/dirk.a

(Note: on Windows, the file extension for the library may be `.lib` in many cases)

Building on Windows
============================================
The included [VisualD](http://www.dsource.org/projects/visuald) project files (see the `visuald` sub-directory)
can be used to build the library files on Windows.

Building in general
============================================
Use the included [makefile](http://github.com/JakobOvrum/Dirk/blob/master/Makefile).

License
============================================
Dirk is licensed under the terms of the MIT license (see the [LICENSE file](http://github.com/JakobOvrum/Dirk/blob/master/LICENSE) for details).
