module irc.protocol;

import std.string;

struct IrcLine
{
	const(char)[] prefix; // Optional
	const(char)[] command;
	const(char)[][] parameters;
}

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
			output: {command: "PING", parameters: ["123456"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel hi!",
			output: {prefix: "foo!bar@baz", command: "PRIVMSG", parameters: ["#channel", "hi!"]}
		},
		{
			input: ":foo!bar@baz PRIVMSG #channel :hello, world!",
			output: {prefix: "foo!bar@baz", command: "PRIVMSG", parameters: ["#channel", "hello, world!"]}
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
			assert(line.parameters == test.output.parameters);
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