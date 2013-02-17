module irc.protocol;

import std.string;
import std.exception;
import core.stdc.string : memmove;

/**
 * Structure representing a parsed IRC message.
 */
struct IrcLine
{
	/// Note: null when the message has no _prefix.
	const(char)[] prefix; // Optional
	///
	const(char)[] command;
	///
	const(char)[][] arguments;
}

/**
 * Thrown when an error occured parsing an IRC message.
 */
class IrcParseErrorException : Exception
{
	this(string msg, string file = __FILE__, uint line = __LINE__)
	{
		super(msg, file, line);
	}
}

struct LineBuffer
{
	private:
	char[] buffer;
	size_t lineStart, bufferPos;
	void delegate(in char[] line) onReceivedLine;

	public:
	this(char[] buffer, void delegate(in char[] line) onReceivedLine)
	{
		this.buffer = buffer;
		this.onReceivedLine = onReceivedLine;
	}

	/// End of the current line.
	size_t position() @property
	{
		return bufferPos;
	}

	/// Notify that n number of bytes have been committed after the current position.
	/// Call with $(D n = 0) to invoke the callback for any lines that were skipped
	/// due an exception being thrown during a previous commit.
	void commit(size_t n)
	{
		auto nextBufferPos = bufferPos + n;

		if(nextBufferPos == buffer.length)
		{
			bufferPos = nextBufferPos;
			nextBufferPos = moveDown();
		}

		foreach(i; bufferPos .. nextBufferPos - 1)
		{
			if(buffer[i .. i + 2] == "\r\n")
			{
				auto line = buffer[lineStart .. i];

				lineStart = i + 2;

				// If onReceivedLine throws, we want to just skip
				// the the current line, leaving the next lines
				// to be parsed on the next commit.
				bufferPos = lineStart;

				onReceivedLine(line);
			}
		}

		bufferPos = nextBufferPos;
	}
	
	private:
	size_t moveDown()
	{
		enforceEx!IrcParseErrorException(lineStart != 0, "line too long for buffer");

		auto length = bufferPos - lineStart;
		memmove(buffer.ptr, buffer.ptr + lineStart, length);
		lineStart = 0;
		bufferPos = 0;

		return length;
	}
}

// [:prefix] <command> <parameters ...> [:long parameter]
// TODO: do something about the allocation of the argument array
bool parse(const(char)[] raw, out IrcLine line)
{	
	if(raw[0] == ':')
	{
		raw = raw[1..$];
		line.prefix = raw.munch("^ ");
		raw.munch(" ");
	}
	
	line.command = raw.munch("^ ");
	raw.munch(" ");
	
	const(char)[] params = raw.munch("^:");
	while(params.length > 0)
	{
		line.arguments ~= params.munch("^ ");
		params.munch(" ");
	}
	
	if(raw.length > 0)
		line.arguments ~= raw[1..$];
		
	return true;
}

version(unittest)
{
	import std.stdio;
}

unittest
{
	struct InputOutput
	{
		char[] input;
		IrcLine output;
		bool valid = true;
	}
	
	static InputOutput[] testData = [
		{
			input: "PING 123456".dup,
			output: {command: "PING", arguments: ["123456"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel hi!".dup,
			output: {prefix: "foo!bar@baz", command: "PRIVMSG", arguments: ["#channel", "hi!"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel :hello, world!".dup,
			output: {prefix: "foo!bar@baz", command: "PRIVMSG", arguments: ["#channel", "hello, world!"]}
		}
	];
	
	foreach(i, test; testData)
	{
		IrcLine line;
		bool succ = parse(test.input, line);

		scope(failure)
		{
			writefln("irc.protocol.parse unittest failed, test #%s", i + 1);
			writefln(`prefix: "%s"`, line.prefix);
			writefln(`command: "%s"`, line.command);
			writefln(`arguments: "%s"`, line.arguments);
		}

		if(test.valid)
		{
			assert(line.prefix == test.output.prefix);
			assert(line.command == test.output.command);
			assert(line.arguments == test.output.arguments);
		}
		else
			assert(!succ);
	}
}

/**
 * Structure representing an IRC user.
 */
struct IrcUser
{
	///
	const(char)[] nick;
	///
	const(char)[] userName;
	///
	const(char)[] hostName;
}

/**
 * Create an IRC user from a message prefix.
 */
IrcUser parseUser(const(char)[] prefix)
{
	IrcUser user;
	
	if(prefix !is null)
	{
		user.nick = prefix.munch("^!");
		if(prefix.length > 0)
		{
			prefix = prefix[1..$];
			user.userName = prefix.munch("^@");
			prefix = prefix[1..$];
			user.hostName = prefix;
		}
	}
	
	return user;
}

unittest
{
	IrcUser user;
	
	user = parseUser("foo!bar@baz");
	assert(user.nick == "foo");
	assert(user.userName == "bar");
	assert(user.hostName == "baz");
	
	// TODO: figure out which field to fill with prefixes like "irc.server.net"
}