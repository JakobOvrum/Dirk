/**
 * Implements the Client-To-Client Protocol (CTCP).
 * Specification:
 *   $(HTTP ctcp.doc, www.irchelp.org/irchelp/rfc/ctcpspec.html)
 */
module irc.ctcp;

import std.algorithm;
import std.array;
import std.range;
import std.string;
import std.traits;

private:
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
	import std.algorithm : joiner;
	
	assert(
	    values("one", "two", "three")
	    .joiner(" ")
	    .array() == "one two three");
}

enum CtcpToken : char
{
	delimiter = 0x01,
	quote = 0x10,
}

/**
 * Low-level quote a message.
 * Returns:
 *   Input range for lazily quoting the message
 */
auto lowQuote(Range)(Range payload) if(isInputRange!Range)
{
	alias ubyte C;
	
	static if(is(Range : const(char)[]))
		alias const(ubyte)[] R;
	else
		alias Range R;
	
	static struct Quoter
	{
		private:
		R data;
		C override_;
		
		public:
		bool empty()
		{
			return override_ == C.init && data.empty;
		}
		
		C front()
		{
			if(override_ != C.init)
				return override_;
			
			auto front = data.front;
			if(front == '\0' || front == '\r' || front == '\n')
				return CtcpToken.quote;
			
			return front;
		}
		
		void popFront()
		{
			if(override_ != C.init)
			{
				override_ = C.init;
				return;
			}
			
			char prev = data.front;
			
			switch(prev)
			{
				case '\0':
					override_ = '0';
					break;
				case '\r':
					override_ = 'r';
					break;
				case '\n':
					override_ = 'n';
					break;
				case CtcpToken.quote:
					override_ = CtcpToken.quote;
					break;
				default:
			}
			
			data.popFront();
		}
	}

	return Quoter(cast(R)payload);
}

/**
* Low-level dequote a message.
* Returns:
*   Input range for lazily dequoting the message
*/
auto lowDequote(R)(R quoted)
{
	static struct Dequoter
	{
		private:
		R remaining;
		bool wasQuote = false;

		public:
		bool empty() const pure
		{
			if(remaining.length == 1 && remaining[0] == CtcpToken.quote)
				return true;

			return remaining.empty;
		}

		char front() pure
		{
			char first = remaining[0];

			wasQuote = first == CtcpToken.quote;
			
			if(wasQuote)
			{
				char next = remaining[1];

				switch(next)
				{
					case '0':
						return '\0';
					case 'r':
						return '\r';
					case 'n':
						return '\n';
					default:
						return next;
				}
			}
			else
				return first;
		}

		void popFront() pure
		{
			remaining = remaining[wasQuote? 2 : 1 .. $];
		}
	}

	return Dequoter(quoted);
}

unittest
{
	string plain, quoted;

	plain = "hello, world";
	quoted = "hello, world";

	assert(plain.lowQuote().array() == quoted);
	assert(quoted.lowDequote().array() == plain);

	plain = "hello, \n\r\0world";
	quoted = "hello, \x10n\x10r\x100world";

	assert(plain.lowQuote().array() == quoted);
	assert(quoted.lowDequote().array() == plain);
}

/**
* Mid-level quote a message.
* Returns:
*   Input range for lazily quoting the message
*/
auto ctcpQuote(Range)(Range payload) if(isInputRange!Range)
{
	alias ubyte C;
	
	static if(is(Range : const(char)[]))
		alias const(ubyte)[] R;
	else
		alias Range R;
	
	static struct Quoter
	{
		private:
		R data;
		C override_;
		
		public:
		bool empty()
		{
			return override_ == C.init && data.empty;
		}
		
		C front()
		{
			if(override_ != C.init)
				return override_;
			
			auto front = data.front;
			if(front == CtcpToken.delimiter)
				return '\\';
			
			return front;
		}
		
		void popFront()
		{
			if(override_ != C.init)
			{
				override_ = C.init;
				return;
			}
			
			char prev = data.front;
			
			switch(prev)
			{
				case '\\':
					override_ = '\\';
					break;
				case CtcpToken.delimiter:
					override_ = 'a';
					break;
				default:
			}
			
			data.popFront();
		}
	}

	return Quoter(cast(R)payload);
}

unittest
{
	import std.array : array;
	
	assert(ctcpQuote("hello, world").array() == "hello, world");
	assert(ctcpQuote("\\hello, \x01world\x01").array() == `\\hello, \aworld\a`);
	assert(ctcpQuote(`hello, \world\`).array() == `hello, \\world\\`);
}

/**
* Mid-level dequote a message.
* Returns:
*   Input range for lazily dequoting the message
*/
auto ctcpDequote(R)(R quoted)
{
	static struct Dequoter
	{
		private:
		R remaining;
		bool wasQuote = false;

		public:
		bool empty() const pure
		{
			if(remaining.length == 1 && remaining[0] == CtcpToken.quote)
				return true;

			return remaining.empty;
		}

		char front() pure
		{
			char first = remaining[0];

			wasQuote = first == '\\';
			
			if(wasQuote)
			{
				char next = remaining[1];

				switch(next)
				{
					case 'a':
						return CtcpToken.delimiter;
					default:
						return next;
				}
			}
			else
				return first;
		}

		void popFront() pure
		{
			remaining = remaining[wasQuote? 2 : 1 .. $];
		}
	}

	return Dequoter(quoted);
}

unittest
{
	import std.algorithm : equal;

	auto example = "Hi there!\nHow are you? \\K?";
	
	auto ctcpQuoted = example.ctcpQuote();
	auto lowQuoted = ctcpQuoted.lowQuote();
	
	auto lowDequoted = lowQuoted.array().lowDequote();
	auto ctcpDequoted = lowDequoted.array().ctcpDequote();
	
	assert(cast(string)ctcpQuoted.array() == "Hi there!\nHow are you? \\\\K?");
	assert(cast(string)lowQuoted.array() == "Hi there!\x10nHow are you? \\\\K?");
	
	assert(lowDequoted.equal(ctcpQuoted));
	assert(ctcpDequoted.array() == example);
}

ubyte[] delimBuffer = [CtcpToken.delimiter];

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

public:
/**
 * Create a CTCP message with the given tag and data,
 * or with the tag and data provided pre-combined.
 * Returns:
 *   Input range for producing the message
 */
auto ctcpMessage(in char[] tag, in char[] data)
{
	alias const(ubyte)[] Ascii;
		
	auto message = values(cast(Ascii)tag, cast(Ascii)data)
	             .joiner(cast(Ascii)" ")
	             .ctcpQuote()
	             .lowQuote();

	return chain(delimBuffer, message, delimBuffer).castRange!char;
}

/// Ditto
auto ctcpMessage(in char[] contents)
{
	return chain(delimBuffer, contents.ctcpQuote().lowQuote(), delimBuffer).castRange!char;
}

///
unittest
{
	char[] msg;
	
	msg = ctcpMessage("ACTION", "test \n123").array();
	assert(msg == "\x01ACTION test \x10n123\x01");
	
	msg = ctcpMessage("FINGER").array();
	assert(msg == "\x01FINGER\x01");
	
	msg = ctcpMessage("TEST", "\\test \x01 \r\n\0\x10").array();
	assert(msg == "\x01TEST \\\\test \\a \x10r\x10n\x100\x10\x10\x01");
}

