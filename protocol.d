module irc.protocol;

import std.string;
import std.exception;
import core.stdc.string : memmove;

struct IrcLine
{
	const(char)[] prefix; // Optional
	const(char)[] command;
	const(char)[][] arguments;
}

class IrcParseErrorException : Exception
{
	this(string msg, string file = __FILE__, uint line = __LINE__)
	{
		super(msg, file, line);
	}
}

enum ParseState
{
	Begin, // -> Prefix | Command
	Prefix, // -> Command
	Command, // -> Argument | LastArgument | End
	Argument, // -> LastArgument | End
	LastArgument, // -> End
	End
}

struct IrcParser
{
	private:
	ParseState state;
	char[] buffer;
	size_t headPos, tailPos;

	public:
	this(char[] buffer)
	{
		this.buffer = buffer;
	}

	size_t head() const pure @property
	{
		return headPos;
	}

	size_t tail() const pure @property
	{
		return tailPos;
	}

	ParseState currentState() const pure @property
	{
		return state;
	}
	
	// TODO: what happens if it stops just before the last-argument colon?
	bool parse(size_t incoming, ref IrcLine line) pure
	{
		tailPos += incoming;
		auto pos = buffer[headPos .. tailPos];

		void eat(size_t n)
		{
			pos = pos[n .. $];
			headPos += n;
		}

		bool isEnd()
		{
			return pos.length > 0 && pos[0] == '\r';
		}
		
		auto lastHead = headPos;
		auto lastState = state;
		while(tailPos - headPos > 0)
		{
			fsm:
			final switch(state) with(ParseState)
			{
				case Begin:
					if(pos[0] == ':')
					{
						eat(1);
						state = Prefix;
					}
					else
					{
						state = Command;
					}
					break;
				case Prefix:
					foreach(i, char c; pos)
					{
						if(c == ' ')
						{
							line.prefix = pos[0 .. i];
							eat(i + 1);
							
							state = Command;
							break fsm;
						}
					}
					break;
				case Command:
					foreach(i, char c; pos)
					{
						if(c == ' ' || c == ':' || c == '\r')
						{
							line.command = pos[0 .. i];
							eat(c == '\r'? i : i + 1);
							
							if(isEnd())
								state = End;
							else if(pos.length > 0 && pos[0] == ':')
								state = LastArgument;
							else
								state = Argument;

							break fsm;
						}
					}
					break;
				case Argument:
					foreach(i, char c; pos)
					{
						if(c == ' ' || c == ':' || c == '\r')
						{
							line.arguments ~= pos[0 .. i];
							eat(c == '\r'? i : i + 1);
							
							if(isEnd())
								state = End;
							else if(pos.length > 0 && pos[0] == ':')
								state = LastArgument;
							else
								state = Argument;

							break fsm;
						}
					}
					break;
				case LastArgument:
					foreach(i, char c; pos)
					{
						if(c == '\r')
						{
							line.arguments ~= pos[1 .. i]; // Don't include leading colon
							eat(i); // Leave '\r' like the other paths leading to End
							
							state = End;
							break fsm;
						}
					}
					break;
				case End:
					if(pos.length >= 2)
					{
						if(pos[0..2] == "\r\n")
						{
							eat(2);
							state = Begin;
							return true;
						}
						else
							throw new IrcParseErrorException("CR must be followed by LF");
					}
					break;
			}

			if(state == lastState && headPos == lastHead)
				break;

			lastState = state;
			lastHead = headPos;
		}
		return false;
	}

	void moveDown()
	{
		auto len = tailPos - headPos;
		memmove(buffer.ptr, buffer.ptr + headPos, len);
		headPos = 0;
		tailPos = len;
	}
}

/+
// [:prefix] <command> <parameters ...> [:long parameter]
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
		line.parameters ~= params.munch("^ ");
		params.munch(" ");
	}
	
	if(raw.length > 0)
		line.parameters ~= raw[1..$];
		
	return true;
}+/

bool parse(char[] raw, out IrcLine line)
{
	auto parser = IrcParser(raw);
	enforce(parser.parse(raw.length, line), "incomplete raw IRC line");
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
			input: "PING 123456\r\n".dup,
			output: {command: "PING", arguments: ["123456"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel hi!\r\n".dup,
			output: {prefix: "foo!bar@baz", command: "PRIVMSG", arguments: ["#channel", "hi!"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel :hello, world!\r\n".dup,
			output: {prefix: "foo!bar@baz", command: "PRIVMSG", arguments: ["#channel", "hello, world!"]}
		}
	];
	
	foreach(i, test; testData)
	{
		scope(failure) writefln("irc.protocol.parse unittest failed, test #%s:", i + 1);
		
		IrcLine line;
		bool succ = parse(test.input, line);
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

struct IrcUser
{
	const(char)[] nick;
	const(char)[] userName;
	const(char)[] hostName;
}

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