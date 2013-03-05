/// Utilities not related to IRC.
module irc.util;

import core.exception : OutOfMemoryError;
import core.stdc.stdlib : malloc, free;

import std.algorithm;
import std.array;
import std.conv : emplace;
import std.exception;
import std.range;
import std.traits;

auto values(Elems...)(auto ref Elems elems) if(is(CommonType!Elems))
{
	alias CommonType!Elems ElemType;

	static struct StaticArray
	{
		ElemType[Elems.length] data = void;
		size_t i = 0;
		
		bool empty() const
		{
			return i == data.length;
		}
		
		ElemType front() const pure
		{
			return data[i];
		}
		
		void popFront() pure
		{
			++i;
		}
		
		enum length = data.length;
	}
	
	StaticArray arr;
	
	foreach(i, ref elem; elems)
		arr.data[i] = elem;
	
	return arr;
}

unittest
{
	assert(
	    values("one", "two", "three")
	    .joiner(" ")
	    .array() == "one two three");
}

auto castRange(T, R)(R range)
{
	static struct Casted
	{
		R r;
		
		T front()
		{
			return cast(T)r.front;
		}
		
		alias r this;
	}
	
	return Casted(range);
}

T* alloc(T)()
{
	auto p = malloc(T.sizeof);
	enforceEx!OutOfMemoryError(p);
	auto block = p[0 .. T.sizeof];
	return emplace!T(block);
}

void dealloc(T)(T* p)
{
	free(p);
}
