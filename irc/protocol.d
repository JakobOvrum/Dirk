module irc.protocol;

import irc.exception;
import irc.linebuffer;

import std.algorithm;
import std.array;
import std.exception;
import std.string;
import std.typetuple : TypeTuple;

@safe:

enum IRC_MAX_COMMAND_PARAMETERS = 15; // RFC2812

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
	const(char)[][] arguments() @property pure nothrow @nogc
	{
		return argumentBuffer[0 .. numArguments];
	}

	private const(char)[][IRC_MAX_COMMAND_PARAMETERS] argumentBuffer;
	private size_t numArguments;
}

/// List of the four valid channel prefixes;
/// &, #, + and !.
alias channelPrefixes = TypeTuple!('&', '#', '+', '!');

// [:prefix] <command> <parameters ...> [:long parameter]
// TODO: do something about the allocation of the argument array
bool parse(const(char)[] raw, out IrcLine line) pure @nogc
{
	if(raw[0] == ':')
	{
		raw = raw[1 .. $];
		line.prefix = raw.munch("^ ");
		raw.munch(" ");
	}

	line.command = raw.munch("^ ");

	auto result = raw.findSplit(" :");

	const(char)[] args = result[0];
	args.munch(" ");

	while(args.length)
	{
		assert(line.numArguments < line.argumentBuffer.length);
		line.argumentBuffer[line.numArguments++] = args.munch("^ ");
		args.munch(" ");
	}

	if(!result[2].empty)
	{
		assert(line.numArguments < line.argumentBuffer.length);
		line.argumentBuffer[line.numArguments++] = result[2];
	}

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

		struct Output
		{
			string prefix, command;
			string[] arguments;
		}
		Output output;

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
		},
		{
			input: ":foo!bar@baz 005 testnick CHANLIMIT=#:120 :are supported by this server",
			output: {prefix: "foo!bar@baz", command: "005", arguments: ["testnick", "CHANLIMIT=#:120", "are supported by this server"]}
		},
		{
			input: ":nick!~ident@00:00:00:00::00 PRIVMSG #some.channel :some message",
			output: {prefix: "nick!~ident@00:00:00:00::00", command: "PRIVMSG", arguments: ["#some.channel", "some message"]}
		},
		{
			input: ":foo!bar@baz JOIN :#channel",
			output: {prefix: "foo!bar@baz", command: "JOIN", arguments: ["#channel"]}
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
	version(none) string toString() const
	{
		return format("%s!%s@%s", nickName, userName, hostName);
	}

	void toString(scope void delegate(const(char)[]) @safe sink) const
	{
		if(nickName)
			sink(nickName);

		if(userName)
		{
			sink("!");
			sink(userName);
		}

		if(hostName)
		{
			sink("@");
			sink(hostName);
		}
	}

	unittest
	{
		auto user = IrcUser("nick", "user", "host");
		assert(format("%s", user) == "nick!user@host");

		user.hostName = null;
		assert(format("%s", user) == "nick!user");

		user.userName = null;
		assert(format("%s", user) == "nick");

		user.hostName = "host";
		assert(format("%s", user) == "nick@host");
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
