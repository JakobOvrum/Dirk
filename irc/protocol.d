module irc.protocol;

import irc.exception;
import irc.linebuffer;

import std.algorithm;
import std.array;
import std.exception;
import std.string;
import std.typetuple : TypeTuple;

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

/// List of the four valid channel prefixes;
/// &, #, + and !.
alias channelPrefixes = TypeTuple!('&', '#', '+', '!');

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
	const(char)[] nickName;
	///
	const(char)[] userName;
	///
	const(char)[] hostName;

	deprecated alias nick = nickName;

	// TODO: Change to use sink once formattedWrite supports them
	string toString() const
	{
		return format("%s!%s@%s", nickName, userName, hostName);
	}

	static:
	/**
	 * Create an IRC user from a message prefix.
	 */
	IrcUser fromPrefix(const(char)[] prefix)
	{
		IrcUser user;

		if(prefix !is null)
		{
			user.nickName = prefix.munch("^!");
			if(prefix.length > 0)
			{
				prefix = prefix[1 .. $];
				user.userName = prefix.munch("^@");
				if(prefix.length > 0)
					user.hostName = prefix[1 .. $];
			}
		}

		return user;
	}

	/**
	 * Create users from userhost reply.
	 */
	size_t parseUserhostReply(ref IrcUser[5] users, in char[] reply)
	{
		auto splitter = reply.splitter(" ");
		foreach(i, ref user; users)
		{
			if(splitter.empty)
				return i;

			auto strUser = splitter.front;

			if(strUser.strip.empty) // ???
				return i;

			user.nickName = strUser.munch("^=");
			strUser.popFront();

			user.userName = strUser.munch("^@");
			if(!strUser.empty)
				strUser.popFront();

			if(user.userName[0] == '-' || user.userName[0] == '+')
			{
				// TODO: away stuff
				user.userName.popFront();
			}

			user.hostName = strUser;

			splitter.popFront();
		}

		return 5;
	}
}

unittest
{
	IrcUser user;

	user = IrcUser.fromPrefix("foo!bar@baz");
	assert(user.nickName == "foo");
	assert(user.userName == "bar");
	assert(user.hostName == "baz");

	// TODO: figure out which field to fill with prefixes like "irc.server.net"
}