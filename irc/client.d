module irc.client;

import irc.protocol;
public import irc.protocol : IrcUser;
import irc.ctcp;

import std.socket;
public import std.socket : InternetAddress;

import std.exception;
import std.algorithm;
import std.array;
import std.range;
import std.regex; // TEMP: For EOL identification
import std.string : format, sformat;

//debug=Dirk;
debug(Dirk) static import std.stdio;
debug(Dirk) import std.conv;

enum IRC_MAX_LEN = 510;

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
}

/**
 * Thrown if an unconnected client was passed when a connected client was expected.
 */
class UnconnectedClientException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

/**
 * Represents an IRC client connection.
 */
class IrcClient
{
	private:
	string m_nick = "dirkuser";
	string m_user = "dirk";
	string m_name = "dirk";
	InternetAddress m_address = null;
	
	char[] buffer;
	LineBuffer lineBuffer;

	package:
	Socket socket = null;

	// These allow for a layered connection, e.g. SSL
	protected:
	Socket createConnection(InternetAddress serverAddress)
	{
		return new TcpSocket(serverAddress);
	}

	size_t rawRead(void[] buffer)
	{
		return socket.receive(buffer);
	}

	size_t rawWrite(in void[] data)
	{
		return socket.send(data);
	}

	public:
	/**
	 * Create a new unconnected IRC client.
	 *
	 * User information should be configured before connecting.
	 * Only the nick name can be changed after connecting.
	 * Event callbacks can be added before and after connecting.
	 * See_Also:
	 *   $(MREF IrcClient.connect)
	 */
	this()
	{
		buffer = new char[](2048);

		void onReceivedLine(in char[] rawLine)
		{
			debug(Dirk) std.stdio.writefln(`>> "%s" pos: %s`, rawLine, lineBuffer.position);

			IrcLine line;

			auto succeeded = parse(rawLine, line);
			assert(succeeded);

			handle(line);
		}

		lineBuffer = LineBuffer(buffer, &onReceivedLine);
	}
	
	/**
	 * Connect this client to a server.
	 * Params:
	 *   serverAddress = address of server
	 *   type = _type of connection
	 */
	void connect(InternetAddress serverAddress)
	{
		socket = createConnection(serverAddress);
		m_address = serverAddress;
		
		writef("USER %s * * :%s", userName, realName);
		writef("NICK %s", nick);
	}
	
	/**
	 * Read once from the socket, parse all complete messages and invoke registered callbacks.
	 * See_Also:
	 *   $(DPREF clientset, IrcClientSet.run)
	 */
	void read()
	{
		enforceEx!UnconnectedClientException(connected, "cannot read from unconnected IrcClient");
		
		auto received = rawRead(buffer[lineBuffer.position .. $]);
		if(received == Socket.ERROR)
		{
			throw new Exception("socket read operation failed");
		}
		else if(received == 0)
		{
			debug(Dirk) std.stdio.writeln("remote ended connection");
			socket.close();
			return;
		}

		lineBuffer.commit(received);
	}

	static char[1540] formatBuffer;
	
	/**
	 * Write a raw message to the connection stream.
	 *
	 * If there are more than one argument, then the first argument is formatted with the subsequent ones.
	 * Arguments must not contain newlines.
	 * Messages longer than 510 will be cut off.
	 * Params:
	 *   rawline = line to send
	 *   fmtArgs = format arguments for the first argument
	 * See_Also:
	 *   $(STDREF format, formattedWrite)
	 * Throws:
	 *   $(MREF UnconnectedClientException) if this client is not connected.
	 */
	void writef(T...)(const(char)[] rawline, T fmtArgs)
	{
		enforceEx!UnconnectedClientException(connected, "cannot write to unconnected IrcClient");
		
		static if(fmtArgs.length > 0)
		{
			rawline = sformat(formatBuffer, rawline, fmtArgs);
		}
		
		debug(Dirk) std.stdio.writefln(`<< "%s" (length: %d)`, rawline, rawline.length);

		rawWrite(rawline);
		rawWrite("\r\n"); // TODO: should be in one call to send
	}

	// Takes care of splitting 'message' into multiple messages when necessary
	private void sendMessage(string method)(in char[] target, in char[] message)
	{
		static linePattern = ctRegex!(`[^\r\n]+`, "g");

		immutable maxMsgLength = IRC_MAX_LEN - method.length - 1 - target.length - 2;

		foreach(m; match(message, linePattern))
		{
			auto line = cast(const ubyte[])m.hit;
			foreach(chunk; line.chunks(maxMsgLength))
				writef(method ~ " %s :%s", target, cast(const char[])chunk);
		}
	}
	
	/**
	 * Send lines of chat to a channel or user.
	 * Each line in $(D message) is sent as one message.
	 * Lines exceeding the IRC message length limit will be
	 * split up into multiple messages.
	 * Params:
	 *   target = channel or nick name to _send to
	 *   message = _message(s) to _send. Can contain multiple lines.
	 * Throws:
	 *   $(MREF UnconnectedClientException) if this client is not connected.
	 */
	void send(in char[] target, in char[] message)
	{
		sendMessage!"PRIVMSG"(target, message);
	}

	/**
	* Send formatted lines of chat to a channel or user.
	* Each line in $(D message) is sent as one message.
	* Lines exceeding the IRC message length limit will be
	* split up into multiple messages.
	* Params:
	*   target = channel or nick name to _send to
	*   fmt = message format
	*   fmtArgs = format arguments
	* Throws:
	*   $(MREF UnconnectedClientException) if this client is not connected.
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
	 * Each line in $(D message) is sent as one notice.
	 * Lines exceeding the IRC message length limit will be
	 * split up into multiple notices.
	 * Params:
	 *   target = channel or nick name to notice
	 *   message = notices(s) to send. Can contain multiple lines.
	 * Throws:
	 *   $(MREF UnconnectedClientException) if this client is not connected.
	 */
	void notice(in char[] target, in char[] message)
	{
		sendMessage!"NOTICE"(target, message);
	}

	/**
	 * Send formatted notices to a channel or user.
	 * Each line in $(D message) is sent as one notice.
	 * Lines exceeding the IRC message length limit will be
	 * split up into multiple notices.
	 * Params:
	 *   target = channel or nick name to _send to
	 *   fmt = message format
	 *   fmtArgs = format arguments
	 * Throws:
	 *   $(MREF UnconnectedClientException) if this client is not connected.
	 * See_Also:
	 *   $(STDREF format, formattedWrite)
	 */
	void noticef(FormatArgs...)(in char[] target, in char[] fmt, FormatArgs fmtArgs)
	{
		// TODO: use a custom format writer that doesn't necessarily allocate
		notice(target, format(fmt, fmtArgs));
	}

	/**
	 * Send a CTCP query to a channel or user.
	 */
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
	 * Check if this client is _connected.
	 * Returns:
	 *   true if this client is _connected.
	 */
	bool connected() const @property
	{
		return socket !is null && socket.isAlive();
	}
	
	/**
	 * Address of the server currently connected to, or null if this client is not connected.
	 */
	inout(InternetAddress) serverAddress() inout pure @property
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
	string nick() const pure @property
	{
		return m_nick;
	}
	
	/// Ditto
	void nick(in char[] newNick) @property
	{
		enforce(!newNick.empty);
		if(connected) // m_nick will be set later if the nick is accepted.
			writef("NICK %s", newNick);
		else
			m_nick = nick.idup;
	}
	
	/// Ditto
	// Duplicated to show up nicer in DDoc - previously used a template and aliases
	void nick(string newNick) @property
	{
		enforce(!newNick.empty);
		if(connected) // m_nick will be set later if the nick is accepted.
			writef("NICK %s", newNick);
		else
			m_nick = newNick;
	}
	
	/**
	 * Join a _channel.
	 * Params:
	 *   channel = _channel to _join
	 * Throws:
	 *   $(MREF UnconnectedClientException) if this client is not connected.
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
	 *   $(MREF UnconnectedClientException) if this client is not connected.
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
	 *   $(MREF UnconnectedClientException) if this client is not connected.
	 */
	void part(in char[] channel)
	{
		writef("PART %s", channel);
	}
	
	/**
	 * Leave a _channel with a parting _message.
	 * Params:
	 *   channel = _channel to leave
	 *   message = parting _message
	 * Throws:
	 *   $(MREF UnconnectedClientException) if this client is not connected.
	 */
	void part(in char[] channel, in char[] message)
	{
		writef("PART %s :%s", channel, message);
	}
	
	/**
	 * Leave and disconnect from the server.
	 * Params:
	 *   message = _quit _message
	 * Throws:
	 *   $(MREF UnconnectedClientException) if this client is not connected.
	 */
	void quit(in char[] message)
	{
		writef("QUIT :%s", message);
		socket.close();
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
	 * Invoked when the requested nick name of the user for this client is already in use.
	 * 
	 * Return a non-null string to provide a new nick. No further callbacks in the list
	 * are called once a callback provides a nick.
	 * Params:
	 *   newnick = the nick name that was requested.
	 * Note:
	 *   The current nick name can be read from the $(MREF IrcClient.nick) property of this client.
	 */
	const(char)[] delegate(in char[] newnick)[] onNickInUse;

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
	 *   time _time the topic was set
	 */
	void delegate(in char[] channel, in char[] nick, in char[] time)[] onTopicInfo;

	/**
	 * Invoked when a _channel is joined or when the user list of a _channel was requested.
	 * This may be invoked several times if the entire user list doesn't fit in a single message.
	 *
	 * Params:
	 *   channel
	 *   names = nick _names of users
	 */
	void delegate(in char[] channel, in char[][] names)[] onNamesList;

	/**
	 * Invoked when the entire user list of a _channel has been sent.
	 * All invocations of onNamesList for channel prior to this message
	 * are part of the same user list.
	 */
	void delegate(in char[] channel)[] onNamesListEnd;
	
	protected:
	IrcUser getUser(in char[] prefix)
	{
		return parseUser(prefix);
	}
	
	private:
	void fireEvent(T, U...)(T[] event, U args)
	{
		foreach(cb; event)
		{
			cb(args);
		}
	}
	
	void handle(ref IrcLine line)
	{
		switch(line.command)
		{
			case "PING":
				writef("PONG :%s", line.arguments[0]);
				break;
			case "433":
				bool handled = false;
				
				foreach(cb; onNickInUse)
				{
					if(auto newNick = cb(line.arguments[1]))
					{
						writef("NICK %s", newNick);
						handled = true;
						break;
					}
				}
				
				if(!handled)
				{
					socket.close();
					throw new IrcErrorException(this, `"433 Nick already in use" was unhandled`);
				}
				break;
			case "PRIVMSG":
				fireEvent(onMessage, getUser(line.prefix), line.arguments[0], line.arguments[1]);
				break;
			case "NOTICE":
				fireEvent(onNotice, getUser(line.prefix), line.arguments[0], line.arguments[1]);
				break;
			case "353":
				fireEvent(onNamesList, line.arguments[2], split(line.arguments[3]));
				break;
			case "366":
				fireEvent(onNamesListEnd, line.arguments[1]);
				break;
			case "332":
				fireEvent(onTopic, line.arguments[1], line.arguments[2]);
				break;
			case "333":
				fireEvent(onTopicInfo, line.arguments[1], line.arguments[2], line.arguments[3]);
				break;
			case "ERROR":
				throw new IrcErrorException(this, line.arguments[0].idup);
			case "001":
				fireEvent(onConnect);
				break;
			default:
				debug(Dirk) std.stdio.writefln(`Unhandled command "%s"`, line.command);
				break;
		}
	}
}