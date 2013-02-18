module loader.posix;

version(Posix):

import core.sys.posix.dlfcn;

void* loadLibrary(in char* name)
{
	return dlopen(name, RTLD_LAZY);
}

void freeLibrary(void* handle)
{
	dlclose(handle);
}

void* loadSymbol(void* handle, in char* sym)
{
	return dlsym(handle, sym);
}
