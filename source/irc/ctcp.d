/**
 * Implements the Client-To-Client Protocol (CTCP).
 * Specification:
 *   $(LINK http://www.irchelp.org/irchelp/rfc/ctcpspec.html)
 */
module irc.ctcp;

import std.algorithm;
import std.array;
import std.range;
import std.string;

import irc.util;

enum CtcpToken : char
{
	delimiter = 0x01,
	quote = 0x10,
}

private:
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
auto lowDequote(Range)(Range quoted)
{
	static if(is(Range : const(char)[]))
		alias const(ubyte)[] R;
	else
		alias Range R;

	static struct Dequoter
	{
		private:
		R remaining;
		bool wasQuote = false;

		public:
		bool empty() const pure
		{
			return remaining.empty;
		}

		ubyte front() pure
		{
			auto front = remaining.front;

			if(wasQuote)
			{
				switch(front)
				{
					case '0':
						return '\0';
					case 'r':
						return '\r';
					case 'n':
						return '\n';
					default:
						break;
				}
			}

			return front;
		}

		private bool skipQuote()
		{
			if(!remaining.empty && remaining.front == CtcpToken.quote)
			{
				remaining.popFront();
				return !remaining.empty;
			}
			else
				return false;
		}

		void popFront()
		{
			remaining.popFront();
			wasQuote = skipQuote();
		}
	}

	auto dequoter = Dequoter(cast(R)quoted);
	dequoter.wasQuote = dequoter.skipQuote();
	return dequoter;
}

unittest
{
	string plain, quoted;

	plain = "hello, world";
	quoted = "hello, world";

	assert(plain.lowQuote().array() == quoted);
	assert(quoted.lowDequote().array() == plain);

	plain = "\rhello, \\t \n\r\0world\0";
	quoted = "\x10rhello, \\t \x10n\x10r\x100world\x100";

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
auto ctcpDequote(Range)(Range quoted)
{
	static if(is(Range : const(char)[]))
		alias const(ubyte)[] R;
	else
		alias Range R;

	static struct Dequoter
	{
		private:
		R remaining;
		bool wasQuote = false;

		public:
		bool empty() const pure
		{
			return remaining.empty;
		}

		char front() pure
		{
			auto front = remaining.front;

			if(wasQuote)
			{
				switch(front)
				{
					case 'a':
						return CtcpToken.delimiter;
					default:
						break;
				}
			}

			return front;
		}

		private bool skipQuote()
		{
			if(!remaining.empty && remaining.front == '\\')
			{
				remaining.popFront();
				return !remaining.empty;
			}
			else
				return false;
		}

		void popFront()
		{
			remaining.popFront();
			wasQuote = skipQuote();
		}
	}

	auto dequoter = Dequoter(cast(R)quoted);
	dequoter.wasQuote = dequoter.skipQuote();
	return dequoter;
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

public:
/**
 * Create a CTCP message with the given tag and data,
 * or with the _tag and _data provided pre-combined.
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

/**
 * Extract CTCP messages from an IRC message.
 * Returns:
 *   Range of CTCP messages, where each element is a range for producing the _message.
 */
auto ctcpExtract(in char[] message)
{
	static struct Extractor
	{
		const(char)[] remaining;
		size_t frontLength;

		bool empty() const pure
		{
			return remaining.empty;
		}

		auto front() const
		{
			return remaining[0 .. frontLength - 1]
			    .ctcpDequote()
			    .lowDequote();
		}

		private size_t findStandaloneDelim() pure
		{
			foreach(i, char c; remaining)
			{
				if(c == CtcpToken.delimiter)
				{
					if((i > 0 && remaining[i - 1] == CtcpToken.delimiter) ||
					   (i < remaining.length - 1 && remaining[i + 1] == CtcpToken.delimiter))
						continue;

					return i;
				}
			}

			return remaining.length;
		}

		void popFront() pure
		{
			remaining = remaining[frontLength .. $];

			auto even = findStandaloneDelim();
			if(even == remaining.length)
			{
				remaining = null;
				return;
			}

			remaining = remaining[even + 1 .. $];

			auto odd = findStandaloneDelim();
			if(odd == remaining.length)
			{
				remaining = null;
				return;
			}

			frontLength = odd + 1;
		}
	}

	auto extractor = Extractor(message);
	extractor.popFront();

	return extractor;
}

unittest
{
	// Chain is useless...
	auto first = ctcpMessage("FINGER").array();
	auto second = ctcpMessage("TEST", "one\r\ntwo").array();

	auto allMsgs = cast(string)("head" ~ first ~ "mid" ~ second ~ "tail");

	auto r = allMsgs.ctcpExtract();
	assert(!r.empty);

	assert(r.front.array() == "FINGER");

	r.popFront();
	assert(!r.empty);

	assert(r.front.array() == "TEST one\r\ntwo");

	r.popFront();
	assert(r.empty);

	allMsgs = "test";
	r = allMsgs.ctcpExtract();
	assert(r.empty);

	allMsgs = "\x01test";
	r = allMsgs.ctcpExtract();
	assert(r.empty);
}
