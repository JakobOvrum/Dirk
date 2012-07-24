module irc.client;

import irc.protocol;
public import irc.protocol : IrcUser;

import std.socket;
public import std.socket : InternetAddress;

import std.exception;
import std.algorithm;
import std.range;
import std.string : format;
debug(Dirk) import std.stdio;
debug(Dirk) import std.conv;

/**
 * Thrown if the server sends an error message to the client.
 */
class IrcErrorException : Exception
{
	IrcClient client;
	
	this(IrcClient client, string message, string file = __FILE__, uint line = __LINE__)
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
	this(string msg, string file = __FILE__, uint line = __LINE__)
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
	
	IrcParser parser;
	IrcLine parsedLine;
	char[] lineBuffer;
	
	package:
	Socket socket = null;

	public:
	/**
	 * Create a new unconnected IRC client.
	 *
	 * Callbacks can be added before connecting.
	 * See_Also:
	 *   connect
	 */
	this()
	{
		lineBuffer = new char[1024];
		parser = IrcParser(lineBuffer);
	}
	
	/**
	 * Connect this client to a server.
	 * Params:
	 *   address = _address of server
	 */
	void connect(InternetAddress address)
	{
		socket = new TcpSocket(address);
		m_address = address;
		
		sendfln("USER %s * * :%s", userName, realName);
		sendfln("NICK %s", nick);
	}
	
	/**
	 * Read once from the socket, parse all complete messages and invoke registered callbacks. 
	 */
	void read()
	{
		enforce(connected, new UnconnectedClientException("cannot read from an unconnected IrcClient"));
		
		auto received = socket.receive(lineBuffer[parser.tail .. $]);
		if(received == Socket.ERROR)
		{
			throw new Exception("socket read operation failed");
		}
		else if(received == 0)
		{
			debug(Dirk) .writeln("remote ended connection");
			socket.close();
			return;
		}

		debug(Dirk_Parsing) .writeln("==== got data ====");
		
		while(parser.parse(received, parsedLine))
		{
			debug(Dirk_Parsing) .writef(`prefix: "%s" cmd: "%s" `, parsedLine.prefix, parsedLine.command);
			debug(Dirk_Parsing) foreach(i, arg; parsedLine.arguments)
			{
				.writef(`arg%s: "%s" `, i, arg);
			}

			debug(Dirk_Parsing) .writeln();

			handle(parsedLine);
			parsedLine = IrcLine();
			debug(Dirk_Parsing) .writefln(`done handling line - state: %s, head: %s tail: %s`, parser.currentState, parser.head, parser.tail);
			received = 0; // Finish parsing the current data
		}

		if(parser.tail == lineBuffer.length)
		{
			throw new Exception("line too long for 1024 byte buffer");
		}

		parser.moveDown();
		debug(Dirk_Parsing) .writefln("==== end of data, moved down (state: %s head: %s tail: %s) ====", parser.currentState, parser.head, parser.tail);
	}
	
	/**
	 * Send a raw message to the server.
	 *
	 * If there are more than one argument, then the first argument is formatted with the subsequent ones.
	 * Arguments must not contain newlines.
	 * Params:
	 *   rawline = line to send
	 *   fmtArgs = format arguments for the first argument
	 * Throws:
	 *   UnconnectedClientException if this client is not connected.
	 */
	void sendfln(T...)(const(char)[] rawline, T fmtArgs)
	{
		enforceEx!UnconnectedClientException(connected, "cannot write to unconnected IrcClient");
		
		static if(fmtArgs.length > 0)
			rawline = format(rawline, fmtArgs);
		
		debug(Dirk) .writefln(`<< "%s"`, rawline);
		socket.send(rawline);
		socket.send("\r\n");
	}
	
	/**
	 * Send a line of chat to a channel or user.
	 * Params:
	 *   target = channel or nick name to _send to
	 *   message = _message to _send
	 */
	void send(in char[] target, in char[] message)
	{
		sendfln("PRIVMSG %s :%s", target, message);
	}

	/**
	* Send a notice to a channel or user.
	* Params:
	*   target = channel or nick name to _notice
	*   message = _message to send
	*/
	void sendNotice(in char[] target, in char[] message)
	{
		sendfln("NOTICE %s :%s", target, message);
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
		return m_user;
	}
	
	/// Ditto	
	void realName(string realName) @property
	{
		enforce(connected, "cannot change real name while connected");
		enforce(!realName.empty);
		m_name = realName;
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
	void userName(string userName) @property
	{
		enforce(!connected, "cannot change user-name while connected");
		enforce(!userName.empty);
		m_user = userName;
	}
	
	/**
	 * Nick name of the user for this client.
	 *
	 * Setting this property when connected can cause the $(D onNickInUse) event to fire.
	 */
	string nick() const pure @property
	{
		return m_nick;
	}
	
	/// Ditto
	void nick(in char[] newNick) @property
	{
		enforce(!nick.empty);
		if(connected) // m_nick will be set later if the nick is accepted.
			sendfln("NICK %s", nick);
		else
			m_nick = nick.idup;
	}
	
	/// Ditto
	// Duplicated to show up nicer in DDoc - previously used a template and aliases
	void nick(string newNick) @property
	{
		enforce(!nick.empty);
		if(connected) // m_nick will be set later if the nick is accepted.
			sendfln("NICK %s", nick);
		else
			m_nick = nick;
	}
	
	/**
	 * Join a _channel.
	 * Params:
	 *   channel = _channel to _join
	 */
	void join(in char[] channel)
	{
		sendfln("JOIN %s", channel);
	}
	
	/**
	 * Join a passworded _channel.
	 * Params:
	 *   channel = _channel to _join
	 *   key = _channel password
	 */
	void join(in char[] channel, in char[] key)
	{
		sendfln("JOIN %s :%s", channel, key);
	}
	
	/**
	 * Leave a _channel.
	 * Params:
	 *   channel = _channel to leave
	 */
	void part(in char[] channel)
	{
		sendfln("PART %s", channel);
	}
	
	/**
	 * Leave a _channel with a parting _message.
	 * Params:
	 *   channel = _channel to leave
	 *   message = parting _message
	 */
	void part(in char[] channel, in char[] message)
	{
		sendfln("PART %s :%s", channel, message);
	}
	
	/**
	 * Leave and disconnect from the server.
	 * Params:
	 *   message = _quit _message
	 */
	void quit(in char[] message)
	{
		sendfln("QUIT :%s", message);
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
	 *   The current nick name can be read from the $(D nick) property of this client.
	 */
	const(char)[] delegate(in char[] newnick)[] onNickInUse;
	
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
				sendfln("PONG :%s", line.arguments[0]);
				break;
			case "433":
				bool handled = false;
				
				foreach(cb; onNickInUse)
				{
					if(auto newNick = cb(line.arguments[1]))
					{
						sendfln("NICK %s", newNick);
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
			case "ERROR":
				throw new IrcErrorException(this, line.arguments[0].idup);
			case "001":
				fireEvent(onConnect);
				break;
			default:
				debug(Dirk) writefln(`Unhandled command "%s"`, line.command);
				break;
		}
	}
}