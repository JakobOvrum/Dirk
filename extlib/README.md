ev.obj
============
This object file is [libev](http://software.schmorp.de/pkg/libev.html) in
OMF format required by DMD on 32-bit Windows, provided for convenience.
Used by the VisualD project files.

It is built as follows:

    gcc -c -O2 -D EV_STANDALONE -D EV_SELECT_IS_WINSOCKET=1 -D EV_USE_SELECT=1 -o ev.o.coff ev.c
    objconv -fomf32 ev.o.coff ev.obj

libev.a
============
[Issue 10671](https://issues.dlang.org/show_bug.cgi?id=10671) necessitates [libev](http://software.schmorp.de/pkg/libev.html) to be built with `-fno-omit-frame-pointer`, so a distribution-agnostic `libev.a` is included and used by default for both x86-32 and x86-64 Linux targets. For other targets that are hit by [issue 10671](https://issues.dlang.org/show_bug.cgi?id=10671), an appropriately compiled library needs to be supplied by the user.

libev license
============
All files in libev are Copyright (C)2007,2008,2009 Marc Alexander Lehmann.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Alternatively, the contents of this package may be used under the terms
of the GNU General Public License ("GPL") version 2 or any later version,
in which case the provisions of the GPL are applicable instead of the
above. If you wish to allow the use of your version of this package only
under the terms of the GPL and not to allow others to use your version of
this file under the BSD license, indicate your decision by deleting the
provisions above and replace them with the notice and other provisions
required by the GPL in this and the other files of this package. If you do
not delete the provisions above, a recipient may use your version of this
file under either the BSD or the GPL.
