module irc.protocol;

import std.string;
import std.exception;

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

struct IrcParser
{
	private:
	enum ParseState
	{
		Begin, // -> Prefix | Command
		Prefix, // -> Command
		Command, // -> Argument | LastArgument | End
		Argument, // -> LastArgument | End
		LastArgument, // -> End
		End
	}
	
	ParseState state;
	const(char)[] buffer, pos;
	size_t leftOver;
	
	public:
	this(const(char)[] buffer)
	{
		this.buffer = buffer;
		this.pos = buffer;
	}
	
	bool parse(size_t incoming, ref IrcLine line)
	{
		size_t length = leftOver + incoming;
		assert((pos.ptr - buffer.ptr) + length <= buffer.length);
		
		while(length)
		{
			fsm:
			final switch(state) with(ParseState)
			{
				case Begin:
					if(pos[0] == ':')
					{
						pos = pos[1..$];
						--length;
						state = Prefix;
					}
					else
					{
						state = Command;
					}
					break;
				case Prefix:
					foreach(i; leftOver .. length)
					{
						if(pos[i] == ' ')
						{
							line.prefix = pos[0 .. i];
							pos = pos[i + 1..$];
							
							state = Command;
							leftOver = 0;
							length -= i;
							break fsm;
						}
					}
					leftOver += incoming;
					break;
				case Command:
					foreach(i; leftOver .. length)
					{
						if(pos[i] == ' ')
						{
							line.command = pos[0 .. i];
							pos = pos[i + 1 .. $];
							
							if(i != length-1 && pos[0] == '\r')
								state = End;
							else
								state = Argument;
							
							leftOver = 0;
							length -= i;
							break fsm;
						}
					}
					leftOver += incoming;
					break;
				case Argument:
					foreach(i; leftOver .. length)
					{
						writefln("i: %s", i);
						if(pos[i] == ' ' || pos[i] == ':')
						{
							line.arguments ~= pos[0 .. i];
							
							if(i != length-1 && pos[0] == '\r')
								state = End;
							else
								state = pos[i] == ':'? LastArgument : Argument;
							
							pos = pos[i + 1 .. $];
							leftOver = 0;
							length -= i;
							break fsm;
						}
					}
					leftOver += incoming;
					break;
				case LastArgument:
					foreach(i; leftOver .. length)
					{
						if(pos[i] == '\r')
						{
							line.arguments ~= pos[0 .. i];
							pos = pos[i + 1 .. $];
							
							state = End;
							
							leftOver = 0;
							length -= i;
						}
					}
					leftOver += incoming;
					break;
				case End:
					if(length >= 2)
					{
						if(pos[0..2] == "\r\n")
						{
							state = Begin;
							return true;
						}
						else
							throw new Exception("CR must be followed by LF");
					}
					break;
			}
		}
		return false;
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

bool parse(const(char)[] raw, out IrcLine line)
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
		string input;
		IrcLine output;
		bool valid = true;
	}
	
	static InputOutput[] testData = [
		{
			input: "PING 123456",
			output: {command: "PING", arguments: ["123456"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel hi!",
			output: {prefix: "foo!bar@baz", command: "PRIVMSG", arguments: ["#channel", "hi!"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel :hello, world!",
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