module irc.client;

import irc.exception;
import irc.linebuffer;
import irc.protocol;
public import irc.protocol : IrcUser;

import irc.ctcp;
import irc.util;

import std.socket;
public import std.socket : InternetAddress;

import std.exception;
import std.algorithm;
import std.array;
import std.range;
import std.regex; // TEMP: For EOL identification
import std.string : format, indexOf, sformat, munch;
import std.traits;
import std.typetuple;
import std.utf : byChar;

//debug=Dirk;
debug(Dirk) static import std.stdio;
debug(Dirk) import std.conv;

enum IRC_MAX_LEN = 510;
/*
 * 63 is the maximum hostname length defined by the protocol.  10 is a common
 * username limit on many networks.  1 is for the `@'.
 * Shamelessly stolen from IRSSI, irc/core/irc-servers.c
 */
enum MAX_USERHOST_LEN = (63 + 10 + 1);

/**
 * Thrown if the server sends an error message to the client.
 */
class IrcErrorException : Exception
{
	IrcClient client;

	this(IrcClient client, string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line);
		this.client = client;
	}

	this(IrcClient client, string message, Exception cause, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line, cause);
		this.client = client;
	}
}

void unsubscribeHandler(T)(ref T[] event, T handler)
{
	enum strategy =
		is(ReturnType!T == void)? SwapStrategy.unstable : SwapStrategy.stable;

	event = event.remove!(e => e == handler, strategy);
}

/**
 * Represents an IRC client connection.
 *
 * Use the separate type $(DPREF tracker, IrcTracker) returned by
 * $(DPREF tracker, track) to keep track of the channels the
 * user for this connection is a member of, and the members of
 * those channels.
 */
class IrcClient
{
	private:
	string m_nick = "dirkuser";
	string m_user = "dirk";
	string m_name = "dirk";
	Address m_address = null;
	bool _connected = false;

	char[] buffer;
	LineBuffer lineBuffer;

	// ISUPPORT data
	// PREFIX
	static immutable char[2][] defaultPrefixedChannelModes = [['@', 'o'], ['+', 'v']]; // RFC2812
	const(char[2])[] prefixedChannelModes = defaultPrefixedChannelModes; // [[prefix, mode], ...]

	// CHANMODES
	string channelListModes = "b"; // Type A
	string channelParameterizedModes = null; // Type B
	string channelNullaryRemovableModes = null; // Type C
	string channelSettingModes = null; // Type D

	// NICKLEN
	enum defaultMaxNickLength = 9;
	ushort _maxNickLength = defaultMaxNickLength;
	bool enforceMaxNickLength = false; // Only enforce max nick length when server has specified one

	// NETWORK
	string _networkName = null;

	// MODES
	enum defaultMessageModeLimit = 3; // RFC2812
	ubyte messageModeLimit = defaultMessageModeLimit;

	package:
	Socket socket;

	public:
	/**
	 * Create a new unconnected IRC client.
	 *
	 * If $(D socket) is provided, it must be an unconnected TCP socket.
	 * Provide an instance of $(RREF ssl, socket, SslSocket) to
	 * use SSL/TLS.
	 *
	 * User information should be configured before connecting.
	 * Only the nick name can be changed after connecting.
	 * Event callbacks can be added both before and after connecting.
	 * See_Also:
	 *   $(MREF IrcClient.connect)
	 */
	this()
	{
		this(new TcpSocket());
	}

	/// Ditto
	this(Socket socket)
	{
		this.socket = socket;
		this.buffer = new char[](2048);
		this.lineBuffer = LineBuffer(buffer, &onReceivedLine);
	}

	private void onReceivedLine(in char[] rawLine)
	{
		debug(Dirk) std.stdio.writefln(`>> "%s" pos: %s`, rawLine, lineBuffer.position);

		IrcLine line;

		auto succeeded = parse(rawLine, line);
		assert(succeeded);

		handle(line);
	}

	/**
	 * Connect this client to a server.
	 * Params:
	 *   serverAddress = address of server
	 *   password = server _password, or $(D null) to specify no _password
	 */
	void connect(Address serverAddress, in char[] password)
	{
		enforceEx!UnconnectedClientException(!connected, "IrcClient is already connected");

		socket.connect(serverAddress);

		m_address = serverAddress;
		_connected = true;

		if(password.length)
			writef("PASS %s", password);

		writef("NICK %s", nickName);
		writef("USER %s * * :%s", userName, realName); // TODO: Initial user-mode argument
	}

	/// Ditto
	void connect(Address serverAddress)
	{
		connect(serverAddress, null);
	}

	/**
	 * Read all available data from the connection,
	 * parse all complete IRC messages and invoke registered callbacks.
	 * Returns:
	 * $(D true) if the connection was closed.
	 * See_Also:
	 *   $(DPREF eventloop, IrcEventLoop.run)
	 */
	bool read()
	{
		enforceEx!UnconnectedClientException(connected, "cannot read from unconnected IrcClient");

		while(connected)
		{
			socket.blocking = false; // TODO: Make writes non-blocking too, so this isn't needed
			auto received = socket.receive(buffer[lineBuffer.position .. $]);
			if(received == Socket.ERROR)
			{
				if(wouldHaveBlocked())
				{
					socket.blocking = true;
					break;
				}
				else
					throw new Exception("socket read operation failed: " ~ socket.getErrorText());
			}
			else if(received == 0)
			{
				debug(Dirk) std.stdio.writeln("remote ended connection");
				socket.close();
				_connected = false;
				return true;
			}

			socket.blocking = true;
			lineBuffer.commit(received);
		}

		return !connected;
	}

	static char[1540] formatBuffer;

	/**
	 * Write a raw IRC protocol message to the connection stream.
	 *
	 * If there is more than one argument, then the first argument is formatted
	 * with subsequent arguments. Arguments must not contain newlines.
	 * Messages longer than 510 characters (UTF-8 code units) will be cut off.
	 * It is the caller's responsibility to ensure a cut-off message is valid.
	 * See_Also:
	 *   $(STDREF format, formattedWrite)
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void writef(T...)(in char[] messageFormat, T formatArgs)
		if(T.length)
	{
		import std.format : formattedWrite;

		enforceEx!UnconnectedClientException(connected, "cannot write to unconnected IrcClient");

		char[512] formatBuffer = void;

		auto tail = formatBuffer[0 .. $ - 2];
		formattedWrite((const(char)[] chunk) {
			immutable chunkSize = min(chunk.length, tail.length);
			tail[0 .. chunkSize] = chunk[0 .. chunkSize];
			tail = tail[chunkSize .. $];
		}, messageFormat, formatArgs);

		auto message = formatBuffer[0 .. $ - tail.length];
		message[$ - 2 .. $] = "\r\n";

		debug(Dirk)
		{
			auto sansNewline = message[0 .. $ - 2];
			std.stdio.writefln(`<< "%s" (length: %d)`, sansNewline, sansNewline.length);
		}

		socket.send(message);
	}

	/// Ditto
	void writef(in char[] rawline)
	{
		enforceEx!UnconnectedClientException(connected, "cannot write to unconnected IrcClient");
		socket.send(rawline[0 .. min($, 510)]);
		socket.send("\r\n");
	}

	enum ADDITIONAL_MSG_LENS
	{
		PRIVMSG=MAX_USERHOST_LEN,
		NOTICE=MAX_USERHOST_LEN
	}
	
	/**
	 * Returns the additional lengthrequirements of a method.
	 * 
	 * Params:
	 * 	method = The method to query.
	 * Returns:
	 * 	The additional lengthrequirements.
	 */
	private static uint additionalMsgLen(string method)()
	{
		static if(staticIndexOf!(method, __traits(allMembers, ADDITIONAL_MSG_LENS))==-1)
		{
			return 0;
		}
		else
		{
			mixin("return ADDITIONAL_MSG_LENS."~method~";");
		}
	}

	unittest{
		assert(additionalMsgLen!("PRIVMSG")()==MAX_USERHOST_LEN);
		assert(additionalMsgLen!("NOTICE")()==MAX_USERHOST_LEN);
		assert(additionalMsgLen!("JOIN")()==0);
	}
	
	// Takes care of splitting 'message' into multiple messages when necessary
	private void sendMessage(string method)(in char[] target, in char[] message)
	{
		static linePattern = ctRegex!(`[^\r\n]+`, "g");

		immutable maxMsgLength = IRC_MAX_LEN - method.length - 1 - target.length - 2 - additionalMsgLen!(method)();
		static immutable lineHead = method ~ " %s :%s";

		foreach(m; match(message, linePattern))
		{
			auto line = cast(const ubyte[])m.hit;
			foreach(chunk; line.chunks(maxMsgLength))
				writef(lineHead, target, cast(const char[])chunk);
		}
	}

	/**
	 * Send lines of chat to a channel or user.
	 * Each line in $(D message) is sent as one _message.
	 * Lines exceeding the IRC _message length limit will be
	 * split up into multiple messages.
	 * Params:
	 *   target = channel or nick name to _send to
	 *   message = _message(s) to _send. Can contain multiple lines.
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void send(in char[] target, in char[] message)
	{
		sendMessage!"PRIVMSG"(target, message);
	}

	/**
	* Send formatted lines of chat to a channel or user.
	* Each line in the formatted result is sent as one message.
	* Lines exceeding the IRC message length limit will be
	* split up into multiple messages.
	* Params:
	*   target = channel or nick name to _send to
	*   fmt = message format
	*   fmtArgs = format arguments
	* Throws:
	*   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	* See_Also:
	*   $(STDREF format, formattedWrite)
	*/
	void sendf(FormatArgs...)(in char[] target, in char[] fmt, FormatArgs fmtArgs)
	{
		// TODO: use a custom format writer that doesn't necessarily allocate
		send(target, format(fmt, fmtArgs));
	}

	/**
	 * Send notices to a channel or user.
	 * Each line in $(D message) is sent as one _notice.
	 * Lines exceeding the IRC _message length limit will be
	 * split up into multiple notices.
	 * Params:
	 *   target = channel or nick name to _notice
	 *   message = notices(s) to send. Can contain multiple lines.
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void notice(in char[] target, in char[] message)
	{
		sendMessage!"NOTICE"(target, message);
	}

	/**
	 * Send formatted notices to a channel or user.
	 * Each line in the formatted result is sent as one notice.
	 * Lines exceeding the IRC message length limit will be
	 * split up into multiple notices.
	 * Params:
	 *   target = channel or nick name to _send to
	 *   fmt = message format
	 *   fmtArgs = format arguments
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 * See_Also:
	 *   $(STDREF format, formattedWrite)
	 */
	void noticef(FormatArgs...)(in char[] target, in char[] fmt, FormatArgs fmtArgs)
	{
		// TODO: use a custom format writer that doesn't necessarily allocate
		notice(target, format(fmt, fmtArgs));
	}

	/**
	 * Send a CTCP _query to a channel or user.
	 */
	// TODO: reuse buffer for output
	void ctcpQuery(in char[] target, in char[] query)
	{
		send(target, ctcpMessage(query).array());
	}

	/// Ditto
	void ctcpQuery(in char[] target, in char[] tag, in char[] data)
	{
		send(target, ctcpMessage(tag, data).array());
	}

	/**
	 * Send a CTCP _reply to a user.
	 */
	void ctcpReply(in char[] targetNick, in char[] reply)
	{
		notice(targetNick, ctcpMessage(reply).array());
	}

	/// Ditto
	void ctcpReply(in char[] targetNick, in char[] tag, in char[] data)
	{
		notice(targetNick, ctcpMessage(tag, data).array());
	}

	/**
	 * Send a CTCP _error message reply.
	 * Params:
	 *   invalidData = data that caused the _error
	 *   error = human-readable _error message
	 */
	void ctcpError(in char[] targetNick, in char[] invalidData, in char[] error)
	{
		notice(targetNick, ctcpMessage("ERRMSG", format("%s :%s", invalidData, error)).array());
	}

	/**
	 * Check if this client is _connected.
	 */
	bool connected() const @property
	{
		return _connected;
	}

	/**
	 * Address of the server this client is currently connected to,
	 * or null if this client is not connected.
	 */
	inout(Address) serverAddress() inout pure @property
	{
		return m_address;
	}

	/**
	 * Real name of the user for this client.
	 *
	 * Cannot be changed after connecting.
	 */
	string realName() const pure @property
	{
		return m_name;
	}

	/// Ditto
	void realName(string newRealName) @property
	{
		enforce(!connected, "cannot change real name while connected");
		enforce(!newRealName.empty);
		m_name = newRealName;
	}

	/**
	 * User name of the user for this client.
	 *
	 * Cannot be changed after connecting.
	 */
	string userName() const pure @property
	{
		return m_user;
	}

	/// Ditto
	void userName(string newUserName) @property
	{
		enforce(!connected, "cannot change user-name while connected");
		enforce(!newUserName.empty);
		m_user = newUserName;
	}

	/**
	 * Nick name of the user for this client.
	 *
	 * Setting this property when connected can cause the $(MREF IrcClient.onNickInUse) event to fire.
	 */
	string nickName() const pure @property
	{
		return m_nick;
	}

	/// Ditto
	void nickName(in char[] newNick) @property
	{
		enforce(!newNick.empty);

		if(enforceMaxNickLength)
			enforce(newNick.length <= _maxNickLength,
				`desired nick name "%s" (%s bytes) is too long; nick name must be within %s bytes`
				.format(newNick, newNick.length, _maxNickLength));

		if(connected) // m_nick will be set later if the nick is accepted.
			writef("NICK %s", newNick);
		else
			m_nick = newNick.idup;
	}

	/// Ditto
	// Duplicated to show up nicer in DDoc - previously used a template and aliases
	void nickName(string newNick) @property
	{
		enforce(!newNick.empty);

		if(enforceMaxNickLength)
			enforce(newNick.length <= _maxNickLength,
				`desired nick name "%s" (%s bytes) is too long; nick name must be within %s bytes`
				.format(newNick, newNick.length, _maxNickLength));

		if(connected) // m_nick will be set later if the nick is accepted.
			writef("NICK %s", newNick);
		else
			m_nick = newNick;
	}

	/// Ditto
	deprecated alias nick = nickName;

	/**
	 * The name of the IRC network the server is part of, or $(D null)
	 * if the server has not advertised the network name.
	 */
	string networkName() const @property nothrow @nogc pure
	{
		return _networkName;
	}

	/**
	 * The maximum number of characters (bytes) allowed in this user's nick name.
	 *
	 * The limit is network-specific.
	 */
	ushort maxNickNameLength() const @property nothrow @nogc pure
	{
		return _maxNickLength;
	}

	/**
	 * Add or remove user modes to/from this user.
	 */
	void addUserModes(in char[] modes...)
	{
		writef("MODE %s +%s", m_nick, modes);
	}

	/// Ditto
	void removeUserModes(in char[] modes...)
	{
		writef("MODE %s -%s", m_nick, modes);
	}

	private void editChannelModes(Modes, Args)(char editAction, in char[] channel, Modes modes, Args args)
		if(allSatisfy!(isInputRange, Modes, Args) && isSomeChar!(ElementType!Modes) && isSomeString!(ElementType!Args))
	in {
		assert(modes.length == args.length);
		assert(modes.length <= messageModeLimit);
	} body {
		writef("MODE %s %c%s %-(%s%| %)", editAction, channel, modes, args);
	}

	private void editChannelList(char editAction, in char[] channel, char list, in char[][] addresses...)
	{
		import std.range : chunks;

		enforce(channelListModes.canFind(list),
			`specified channel mode "` ~ list ~ `" is not a list mode`);

		foreach(chunk; addresses.chunks(messageModeLimit)) // TODO: split up if too long
		{
			if(messageModeLimit <= 16) // arbitrary number
			{
				char[16] modeBuffer = list;
				editChannelModes(editAction, channel, modeBuffer[0 .. chunk.length], chunk);
			}
			else
				editChannelModes(editAction, channel, list.repeat(chunk.length).byChar(), chunk);
		}
	}

	/**
	 * Add or remove an address to/from a _channel list.
	Examples:
	Ban Alice and Bob from _channel #foo:
	------
	client.addToChannelList("#foo", 'b', "Alice!*@*", "Bob!*@*");
	------
	 */
	void addToChannelList(in char[] channel, char list, in char[][] addresses...)
	{
		editChannelList('+', channel, list, addresses);
	}

	/// Ditto
	void removeFromChannelList(in char[] channel, char list, in char[][] addresses...)
	{
		editChannelList('-', channel, list, addresses);
	}

	/**
	 * Add or remove channel modes in the given channel.
	 * Examples:
	 Give channel operator status (+o) to Alice and voice status (+v) to Bob in channel #foo:
	 ------
	client.addChannelModes("#foo", ChannelMode('o', "Alice"), ChannelMode('v', "Bob"));
	 ------
	 */
	struct ChannelMode
	{
		char mode; ///
		const(char)[] argument; /// Ditto
	}

	/// Ditto
	void addChannelModes(in char[] channel, ChannelMode[] modes...)
	{
		import std.range : chunks;

		foreach(chunk; modes.chunks(messageModeLimit)) // TODO: split up if too long
			writef("MODE %s +%s %-(%s%| %)", channel,
				modes.map!(pair => pair.mode),
				modes.map!(pair => pair.argument).filter!(arg => !arg.empty));
	}

	/// Ditto
	void removeChannelModes(in char[] channel, ChannelMode[] modes...)
	{
		import std.range : chunks;

		foreach(chunk; modes.chunks(messageModeLimit)) // TODO: split up if too long
			writef("MODE %s -%s %-(%s%| %)", channel,
				modes.map!(pair => pair.mode),
				modes.map!(pair => pair.argument));
	}

	/**
	 * Join a _channel.
	 * Params:
	 *   channel = _channel to _join
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void join(in char[] channel)
	{
		writef("JOIN %s", channel);
	}

	/**
	 * Join a passworded _channel.
	 * Params:
	 *   channel = _channel to _join
	 *   key = _channel password
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void join(in char[] channel, in char[] key)
	{
		writef("JOIN %s :%s", channel, key);
	}

	/**
	 * Leave a _channel.
	 * Params:
	 *   channel = _channel to leave
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void part(in char[] channel)
	{
		writef("PART %s", channel);
		//fireEvent(onMePart, channel);
	}

	/**
	 * Leave a _channel with a parting _message.
	 * Params:
	 *   channel = _channel to leave
	 *   message = parting _message
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void part(in char[] channel, in char[] message)
	{
		writef("PART %s :%s", channel, message);
	}

	/**
	 * Kick one or more _users from a _channel.
	 *
	 * This _user must have channel operator status in $(D channel).
	 * Params:
	 *   channel = _channel to kick user(s) from
	 *   users = _user(s) to kick
	 *   comment = _comment to broadcast with the _kick message,
	 *      which typically contains the reason the _user is being kicked
	 */
	void kick()(in char[] channel, in char[] user)
	{
		writef("KICK %s %s", channel, user);
	}

	/// Ditto
	void kick()(in char[] channel, in char[] user, in char[] comment)
	{
		writef("KICK %s %s :%s", channel, user, comment);
	}

	/// Ditto
	void kick(Range)(in char[] channel, Range users)
		if(isInputRange!Range && isSomeString!(ElementType!Range))
	{
		writef("KICK %s %(%s%|,%)", channel, users);
	}

	/// Ditto
	void kick(Range)(in char[] channel, Range users, in char[] comment)
		if(isInputRange!Range && isSomeString!(ElementType!Range))
	{
		writef("KICK %s %(%s%|,%) :%s", channel, users, comment);
	}

	/**
	 * Kick users from channels in a single message.
	 *
	 * $(D channelUserPairs) must be a range of $(STDREF typecons, Tuple)
	 * pairs of strings, where the first string is the name of a channel
	 * and the second string is the user to kick from that channel.
	 */
	void kick(Range)(Range channelUserPairs)
		if(isInputRange!Range &&
		   isTuple!(ElementType!Range) && ElementType!Range.length == 2 &&
		   allSatisfy!(isSomeString, ElementType!Range.Types))
	{
		writef("KICK %(%s%|,%) %(%s%|,%)",
			   channelUserPairs.map!(pair => pair[0]),
			   channelUserPairs.map!(pair => pair[1]));
	}

	/// Ditto
	void kick(Range)(Range channelUserPairs, in char[] comment)
		if(isInputRange!Range &&
		   isTuple!(ElementType!Range) && ElementType!Range.length == 2 &&
		   allSatisfy!(isSomeString, ElementType!Range.Types))
	{
		writef("KICK %(%s%|,%) %(%s%|,%) :%s",
			   channelUserPairs.map!(pair => pair[0]),
			   channelUserPairs.map!(pair => pair[1]),
			   comment);
	}

	/**
	 * Query the user name and host name of up to 5 users.
	 * Params:
	 *   nicks = between 1 and 5 nick names to query
	 * See_Also:
	 *   $(MREF IrcClient.onUserhostReply)
	 */
	void queryUserhost(in char[][] nicks...)
	{
		version(assert)
		{
			import core.exception;
			if(nicks.length < 1 || nicks.length > 5)
				throw new RangeError();
		}
		writef("USERHOST %-(%s%| %)", nicks);
	}

	/**
	 * Query information about a particular user.
	 * Params:
	 *   nick = target user's nick name
	 * See_Also:
	 *   $(MREF IrcClient.onWhoisReply)
	 */
	void queryWhois(in char[] nick)
	{
		writef("WHOIS %s", nick);
	}

	/**
	 * Query the list of members in the given channels.
	 * See_Also:
	 *   $(MREF IrcClient.onNameList)
	 */
	void queryNames(in char[][] channels...)
	{
		// TODO: support automatic splitting of messages
		//writef("NAMES %s", channels.map!(channel => channel[]).joiner(","));

		// NOTE: one message per channel because some servers ignore subsequent channels (confirmed: IRCd-Hybrid)
		foreach(channel; channels)
			writef("NAMES %s", channel);
	}

	/**
	 * Leave and disconnect from the server.
	 * Params:
	 *   message = comment sent in _quit notification
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if this client is not connected.
	 */
	void quit(in char[] message)
	{
		writef("QUIT :%s", message);
		socket.close();
		_connected = false;
	}

	/// Invoked when this client has successfully connected to a server.
	void delegate()[] onConnect;

	/**
	 * Invoked when a message is picked up by the user for this client.
	 * Params:
	 *   user = _user who sent the message
	 *   target = message _target. This is either the nick of this client in the case of a personal
	 *   message, or the name of the channel which the message was sent to.
	 */
	void delegate(IrcUser user, in char[] target, in char[] message)[] onMessage;

	/**
	 * Invoked when a notice is picked up by the user for this client.
	 * Params:
	 *   user = _user who sent the notice
	 *   target = notice _target. This is either the nick of this client in the case of a personal
	 *   notice, or the name of the channel which the notice was sent to.
	 */
	void delegate(IrcUser user, in char[] target, in char[] message)[] onNotice;

	/**
	 * Invoked when a user receives a new nickname.
	 *
	 * When the user is this user, the $(MREF IrcClient.nick) property will return the old nickname
	 * until after all $(D _onNickChange) callbacks have been invoked.
	 * Params:
	 *   user = user which nickname was changed; the $(D nick) field contains the old nickname. Can be this user
	 *   newNick = new nickname of user
	 */
	void delegate(IrcUser user, in char[] newNick)[] onNickChange;

	/**
	 * Invoked following a call to $(MREF IrcClient.join) when the _channel was successfully joined.
	 * Params:
	 *   channel = _channel that was successfully joined
	 */
	void delegate(in char[] channel)[] onSuccessfulJoin;

	/**
	 * Invoked when another user joins a channel that this user is a member of.
	 * Params:
	 *   user = joining user
	 *   channel = channel that was joined
	 */
	void delegate(IrcUser user, in char[] channel)[] onJoin;

	/**
	 * Invoked when a user parts a channel that this user is a member of.
	 * Also invoked when this user parts a channel.
	 * Params:
	 *   user = parting user
	 *   channel = channel that was parted
	 */
	void delegate(IrcUser user, in char[] channel)[] onPart;

	// TODO: public?
	// package void delegate(in char[] channel)[] onMePart;

	/**
	* Invoked when another user disconnects from the network.
	* Params:
	*   user = disconnecting user
	*   comment = quit message
	*/
	void delegate(IrcUser user, in char[] comment)[] onQuit;

	/**
	 * Invoked when a user is kicked (forcefully removed) from a channel that this user is a member of.
	 * Params:
	 *   kicker = user that initiated the kick
	 *   channel = channel from which the user was kicked
	 *   kickedNick = nickname of the user that was kicked
	 *   comment = comment sent with the kick; usually describing the reason the user was kicked. Can be null
	 */
	void delegate(IrcUser kicker, in char[] channel, in char[] kickedNick, in char[] comment)[] onKick;

	/**
	 * Invoked when a list of member nick names for a channel are received.
	 *
	 * The list is received after a successful join to a channel by this user,
	 * or when explicitly queried with $(MREF IrcClient.queryNames).
	 *
	 * The list for a single invocation is partial;
	 * the event can be invoked several times for the same channel
	 * as a response to a single trigger. The list is signaled complete
	 * when $(MREF IrcClient.onNameListEnd) is invoked.
	 * Params:
	 *    channel = channel of which the users are members
	 *    nickNames = list of member nicknames
	 */
	void delegate(in char[] channel, in char[][] nickNames)[] onNameList;

	/**
	 * Invoked when the complete list of members of a _channel have been received.
	 * All invocations of $(D onNameList) between invocations of this event
	 * are part of the same member list.
	 * See_Also:
	 *    $(MREF IrcClient.onNameList)
	 */
	void delegate(in char[] channel)[] onNameListEnd;

	/**
	 * Invoked when a CTCP query is received in a message.
	 * $(MREF IrcClient.onMessage) is not invoked for the given message
	 * when onCtcpQuery has a non-zero number of registered handlers.
	 * Note:
	 *   This callback is only invoked when there is a CTCP message at the start
	 *   of the message, and any subsequent CTCP messages in the same message are
	 *   discarded. To handle multiple CTCP queries in one message, use
	 *   $(MREF IrcClient.onMessage) with $(DPREF ctcp, ctcpExtract).
	 */
	void delegate(IrcUser user, in char[] source, in char[] tag, in char[] data)[] onCtcpQuery;

	/**
	 * Invoked when a CTCP reply is received in a notice.
	 * $(MREF IrcClient.onNotice) is not invoked for the given notice
	 * when onCtcpReply has a non-zero number of registered handlers.
	 * Note:
	 *   This callback is only invoked when there is a CTCP message at the start
	 *   of the notice, and any subsequent CTCP messages in the same notice are
	 *   discarded. To handle multiple CTCP replies in one notice, use
	 *   $(MREF IrcClient.onNotice) with $(DPREF ctcp, ctcpExtract).
	 */
	void delegate(IrcUser user, in char[] source, in char[] tag, in char[] data)[] onCtcpReply;

	/**
	 * Invoked when the requested nick name of the user for this client is already in use.
	 *
	 * Return a non-null string to provide a new nick. No further callbacks in the list
	 * are called once a callback provides a nick.
	 * Params:
	 *   newNick = the nick name that was requested.
	 * Note:
	 *   The current nick name can be read from the $(MREF IrcClient.nick) property of this client.
	 */
	const(char)[] delegate(in char[] newNick)[] onNickInUse;

	/**
	 * Invoked when a _channel is joined, a _topic is set in a _channel or when
	 * the current _topic was requested.
	 *
	 * Params:
	 *   channel
	 *   topic = _topic or new _topic for channel
	 */
	void delegate(in char[] channel, in char[] topic)[] onTopic;

	/**
	 * Invoked when a _channel is joined or when the current _topic was requested.
	 *
	 * Params:
	 *   channel
	 *   nick = _nick name of user who set the topic
	 *   time = _time the topic was set
	 */
	void delegate(in char[] channel, in char[] nick, in char[] time)[] onTopicInfo;

	/**
	 * Invoked with the reply of a userhost query.
	 * See_Also:
	 *   $(MREF IrcClient.queryUserhost)
	 */
	void delegate(in IrcUser[] users)[] onUserhostReply;

	/**
	 * Invoked when a WHOIS reply is received.
	 * See_Also:
	 *   $(MREF IrcClient.queryWhois)
	 */
	// TODO: document more, and maybe parse `channels`
	void delegate(IrcUser userInfo, in char[] realName)[] onWhoisReply;

	/// Ditto
	void delegate(in char[] nick, in char[] serverHostName, in char[] serverInfo)[] onWhoisServerReply;

	/// Ditto
	void delegate(in char[] nick)[] onWhoisOperatorReply;

	/// Ditto
	void delegate(in char[] nick, int idleTime)[] onWhoisIdleReply;

	/// Ditto
	void delegate(in char[] nick, in char[][] channels)[] onWhoisChannelsReply;

	/// Ditto
	void delegate(in char[] nick, in char[] accountName)[] onWhoisAccountReply;

	/// Ditto
	void delegate(in char[] nick)[] onWhoisEnd;

	protected:
	IrcUser getUser(in char[] prefix)
	{
		return IrcUser.fromPrefix(prefix);
	}

	private:
	void fireEvent(T, U...)(T[] event, U args)
	{
		foreach(cb; event)
		{
			cb(args);
		}
	}

	bool ctcpCheck(void delegate(IrcUser, in char[], in char[], in char[])[] event,
				   in char[] prefix,
				   in char[] target,
				   in char[] message)
	{
		if(event.empty || message[0] != CtcpToken.delimiter)
			return false;

		auto extractor = message.ctcpExtract();

		if(extractor.empty)
			return false;

		// TODO: re-use buffer
		auto ctcpMessage = cast(string)extractor.front.array();
		auto tag = ctcpMessage.munch("^ ");

		if(!ctcpMessage.empty && ctcpMessage.front == ' ')
			ctcpMessage.popFront();

		fireEvent(
			event,
			getUser(prefix),
			target,
			tag,
			ctcpMessage
		);

		return true;
	}

	// TODO: Switch getting large, change to something more performant?
	void handle(ref IrcLine line)
	{
		import std.conv : to;

		switch(line.command)
		{
			case "PING":
				writef("PONG :%s", line.arguments[0]);
				break;
			case "433":
				void failed433(Exception cause)
				{
					socket.close();
					_connected = false;
					throw new IrcErrorException(this, `"433 Nick already in use" was unhandled`, cause);
				}

				auto failedNick = line.arguments[1];
				bool handled = false;

				foreach(cb; onNickInUse)
				{
					const(char)[] nextNickToTry;

					try nextNickToTry = cb(failedNick);
					catch(Exception e)
						failed433(e);

					if(nextNickToTry)
					{
						writef("NICK %s", nextNickToTry);
						handled = true;
						break;
					}
				}

				if(!handled)
					failed433(null);

				break;
			case "PRIVMSG":
				auto prefix = line.prefix;
				auto target = line.arguments[0];
				auto message = line.arguments[1];

				if(!ctcpCheck(onCtcpQuery, prefix, target, message))
					fireEvent(onMessage, getUser(prefix), target, message);

				break;
			case "NOTICE":
				auto prefix = line.prefix;
				auto target = line.arguments[0];
				auto notice = line.arguments[1];

				if(!ctcpCheck(onCtcpReply, prefix, target, notice))
					fireEvent(onNotice, getUser(prefix), target, notice);

				break;
			case "NICK":
				auto user = getUser(line.prefix);
				auto newNick = line.arguments[0];

				scope(exit)
				{
					if(m_nick == user.nickName)
						m_nick = newNick.idup;
				}

				fireEvent(onNickChange, user, newNick);
				break;
			case "JOIN":
				auto user = getUser(line.prefix);

				if(user.nickName == m_nick)
					fireEvent(onSuccessfulJoin, line.arguments[0]);
				else
					fireEvent(onJoin, user, line.arguments[0]);

				break;
			case "353": // TODO: operator/voice status etc. should be propagated to callbacks
				// line.arguments[0] == client.nick
				version(none) auto type = line.arguments[1];
				auto channelName = line.arguments[2];

				auto names = line.arguments[3].split();

				// Strip channel modes from nick names (TODO: present them to the user in some way)
				foreach(ref name; names)
				{
					while(prefixedChannelModes.map!(pair => pair[0]).canFind(name[0]))
						name = name[1 .. $];
				}

				fireEvent(onNameList, channelName, names);
				break;
			case "366":
				fireEvent(onNameListEnd, line.arguments[1]);
				break;
			case "PART":
				fireEvent(onPart, getUser(line.prefix), line.arguments[0]);
				break;
			case "QUIT":
				fireEvent(onQuit, getUser(line.prefix),
					line.arguments.length? line.arguments[0] : null);
				break;
			case "KICK":
				fireEvent(onKick,
					getUser(line.prefix),
					line.arguments[0],
					line.arguments[1],
					line.arguments.length > 2? line.arguments[2] : null);
				break;
			case "302":
				IrcUser[5] users;
				auto n = IrcUser.parseUserhostReply(users, line.arguments[1]);

				fireEvent(onUserhostReply, users[0 .. n]);
				break;
			case "332":
				fireEvent(onTopic, line.arguments[1], line.arguments[2]);
				break;
			case "333":
				fireEvent(onTopicInfo, line.arguments[1], line.arguments[2], line.arguments[3]);
				break;
			// WHOIS replies
			case "311":
				auto user = IrcUser(
					line.arguments[1], // Nick
					line.arguments[2]); // Username

				fireEvent(onWhoisReply, user, line.arguments[5]);
				break;
			case "312":
				fireEvent(onWhoisServerReply, line.arguments[1], line.arguments[2], line.arguments[3]);
				break;
			case "313":
				fireEvent(onWhoisOperatorReply, line.arguments[1]);
				break;
			case "317":
				import std.conv : to;
				fireEvent(onWhoisIdleReply, line.arguments[1], to!int(line.arguments[2]));
				break;
			case "319":
				auto nickName = line.arguments[1];
				auto channels = split(line.arguments[2]);

				// Strip channel modes from channel names (TODO: present them to the user in some way)
				foreach(ref channel; channels)
				{
					while(prefixedChannelModes.map!(pair => pair[0]).canFind(channel[0]))
						channel = channel[1 .. $];
				}

				fireEvent(onWhoisChannelsReply, nickName, channels);
				break;
			case "318":
				fireEvent(onWhoisEnd, line.arguments[1]);
				break;
			// Non-standard WHOIS replies
			case "307": // UnrealIRCd?
				if(line.arguments[0] == m_nick)
					fireEvent(onWhoisAccountReply, line.arguments[1], line.arguments[1]);
				break;
			case "330": // Freenode
				fireEvent(onWhoisAccountReply, line.arguments[1], line.arguments[2]);
				break;
			// End of WHOIS replies
			case "ERROR":
				_connected = false;
				throw new IrcErrorException(this, line.arguments[0].idup);
			case "005": // ISUPPORT
				// TODO: handle "\xHH" sequences
				auto tokens = line.arguments[1 .. $ - 1]; // trim nick name and "are supported by this server"
				foreach(const token; tokens)
				{
					if(token[0] == '-') // Negation
					{
						auto parameter = token[1 .. $];
						switch(parameter)
						{
							case "NICKLEN":
								_maxNickLength = defaultMaxNickLength;
								enforceMaxNickLength = false;
								break;
							default:
								debug(Dirk) std.stdio.writefln(`Unhandled negation of ISUPPORT parameter "%s"`, parameter);
								break;
						}
					}
					else
					{
						auto sepPos = token.indexOf('=');
						const(char)[] parameter, value;
						if(sepPos == -1)
						{
							parameter = token;
							value = null;
						}
						else
						{
							parameter = token[0 .. sepPos];
							value = token[sepPos + 1 .. $]; // May be empty
						}

						debug(Dirk) std.stdio.writefln(`ISUPPORT parameter "%s" has value "%s"`, parameter, value);

						switch(parameter)
						{
							case "PREFIX":
								if(value.empty)
									prefixedChannelModes = defaultPrefixedChannelModes;
								else
								{
									assert(value[0] == '(');
									auto endParenPos = value.indexOf(')');
									assert(endParenPos != -1 && endParenPos != value.length - 1);
									auto modes = value[1 .. endParenPos];
									auto prefixes = value[endParenPos + 1 .. $];
									assert(modes.length == prefixes.length);
									auto newChannelModes = new char[2][](modes.length);
									foreach(immutable i, ref pair; newChannelModes)
										pair = [prefixes[i], modes[i]];
									prefixedChannelModes = newChannelModes;
									debug(Dirk) std.stdio.writefln("ISUPPORT PREFIX: %s", prefixedChannelModes);
								}
								break;
							case "CHANMODES":
								assert(!value.empty);
								const(char)[][4] modeTypes; // Types A, B, C and D

								value.splitter(',')
									.takeExactly(4)
									.copy(modeTypes[]);

								if(channelListModes != modeTypes[0])
									channelListModes = modeTypes[0].idup;

								if(channelParameterizedModes != modeTypes[1])
									channelParameterizedModes = modeTypes[1].idup;

								if(channelNullaryRemovableModes != modeTypes[2])
									channelNullaryRemovableModes = modeTypes[2].idup;

								if(channelSettingModes != modeTypes[3])
									channelSettingModes = modeTypes[3].idup;
								break;
							case "NICKLEN":
								assert(!value.empty);
								_maxNickLength = to!(typeof(_maxNickLength))(value);
								enforceMaxNickLength = true;
								break;
							case "NETWORK":
								assert(!value.empty);
								_networkName = value.idup;
								break;
							default:
								debug(Dirk) std.stdio.writefln(`Unhandled ISUPPORT parameter "%s"`, parameter);
								break;
						}
					}
				}

				break;
			case "001":
				m_nick = line.arguments[0].idup;
				fireEvent(onConnect);
				break;
			default:
				debug(Dirk) std.stdio.writefln(`Unhandled command "%s"`, line.command);
				break;
		}
	}
}
