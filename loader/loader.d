module loader.loader;

version(Windows)
	import loader.windows;
else version(posix)
	import loader.posix;
else
	static assert(false, "unsupported platform");

import std.exception;
import std.string;

class DynamicLoaderException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(msg, file, line, next);
	}
}

struct DynamicLibrary
{
	private:
	string libraryName;
	void* handle;

	public:
	this(in char[] name)
	{
		auto zName = toStringz(name);

		libraryName = zName[0 .. name.length];

		handle = loadLibrary(zName);

		enforce(handle, new DynamicLoaderException(format(`failed to load library: %s`, libraryName)));
	}

	void resolve(alias funcPtr)(string file = __FILE__, size_t line = __LINE__)
	{
		enum name = __traits(identifier, funcPtr);
		
		funcPtr = cast(typeof(funcPtr))loadSymbol(handle, name);

		enforce(funcPtr, new DynamicLoaderException(
			format(`unable to find symbol "%s" in library "%s"`, name, libraryName),
			file, line));
	}
}
