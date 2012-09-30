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