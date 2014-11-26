module loader.windows;

version(Windows):

import core.sys.windows.windows;

void* loadLibrary(in char* name)
{
	return cast(void*)LoadLibraryA(name);
}

void freeLibrary(void* handle)
{
	FreeLibrary(cast(HMODULE)handle);
}

void* loadSymbol(void* handle, in char* sym)
{
	return cast(void*)GetProcAddress(cast(HMODULE)handle, sym);
}

const(char)[] libraryError()
{
	import std.windows.syserror;
	return sysErrorString(GetLastError());
}
