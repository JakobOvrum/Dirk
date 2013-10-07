module irc.dcc;

import std.algorithm;
import std.array;
import std.exception;
import std.random : uniform;
import std.range;
import std.socket;
import std.typecons;

import irc.protocol;
import irc.client;
import irc.eventloop;

//ffs
version(Windows)
	import std.c.windows.winsock;
else version(Posix)
	import core.sys.posix.netinet.in_;
else
	static assert(false, "ffff");

enum DccChatType
{
	plain, ///
	secure ///
}

/// Thrown when a DCC error occurs.
class DccException : Exception
{
	this(string msg, Throwable next = null, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line, next);
	}
}

/**
 * Hub for new DCC connections.
 */
class DccServer
{
	private:
	IrcEventLoop eventLoop;
	IrcClient client;
	uint clientAddress_ = 0;
	
	ushort portStart, portEnd;
	ushort lastPort;
	
	string queriedNick;
	
	static struct Offer
	{
		enum State { pendingAddress, listening, sending, declined, finished }
		State state;
	}
	
	Offer[] sendQueue;
	
	Tuple!(Socket, ushort) allocatePort()
	{
		auto portRange = iota(portStart, portEnd + 1);
		
		auto ports = portRange.cycle(lastPort);
		ports.popFront(); // skip last used port
		
		size_t tries = 0;
		auto socket = new TcpSocket();
		foreach(lport; ports)
		{
			auto port = cast(ushort)lport;
			try
			{
				auto addr = new InternetAddress(port); // ew :<
				socket.bind(addr);
				lastPort = port;
				return tuple(cast(Socket)socket, port);
			}
			catch(SocketOSException e)
			{
				if(++tries >= portRange.length)
					throw new DccException("no available port in assigned range", e);
			}
		}
		
		assert(false);
	}
	
	// Figure out the client address by getting
	// its hostname from the IRC server
	void queryUserhost()
	{
		queriedNick = client.nick;
		client.queryUserhost(queriedNick);
		client.onUserhostReply ~= &onUserhostReply;
	}
	
	void onUserhostReply(in IrcUser[] users)
	{
		// If a client address has ben set
		// by this point, don't overwrite it.
		if(clientAddress != 0)
		{
			client.onUserhostReply.unsubscribeHandler(&onUserhostReply);
			return;
		}
		
		foreach(ref user; users)
		{
			if(user.nick == queriedNick)
			{
				clientAddress = user.hostName;
				client.onUserhostReply.unsubscribeHandler(&onUserhostReply);
				break;
			}
		}
	}
	
	public:
	/**
	 * Create a new DCC server given the event loop
	 * and IRC _client to be associated with this
	 * server.
	 *
	 * The event loop is used to schedule reads and
	 * writes for open DCC connections.
	 *
	 * The associated IRC _client is used to send
	 * DCC/CTCP notifications as well as to look up
	 * the Internet address to advertise for this
	 * server.
	 */
	this(IrcEventLoop eventLoop, IrcClient client)
	{
		this.eventLoop = eventLoop;
		this.client = client;
		
		setPortRange(49152, 65535);
		
		if(client.connected)
			queryUserhost();
		else
		{
			void onConnect()
			{
				if(clientAddress != 0)
					queryUserhost();
				
				client.onConnect.unsubscribeHandler(&onConnect);
			}
			
			client.onConnect ~= &onConnect;
		}
	}
	
	/**
	 * The IP address of the DCC server in network byte order.
	 *
	 * If not explicitly provided, this defaults to the result of
	 * looking up the hostname for the associated IRC client.
	 */
	uint clientAddress() const pure @property
	{
		return clientAddress_;
	}
	
	/// Ditto
	void clientAddress(uint addr) pure @property
	{
		clientAddress_ = addr;
	}
	
	/// Ditto
	void clientAddress(in char[] hostName) @property
	{
		auto addresses = getAddress(hostName);

		if(addresses.empty)
			return;
		
		auto address = addresses[0];
		clientAddress = htonl((cast(sockaddr_in*)address.name).sin_addr.s_addr);
	}
	
	/// Ditto
	void clientAddress(Address address) @property
	{
		clientAddress = htonl((cast(sockaddr_in*)address.name).sin_addr.s_addr);
	}
	
	/**
	 * Set the port range for accepting connections.
	 *
	 * The server selects a port in this range when
	 * initiating connections. The default range is
	 * 49152–65535. The range is inclusive on both
	 * ends.
	 */
	void setPortRange(ushort lower, ushort upper)
	{
		enforce(lower < upper);
		
		portStart = lower;
		portEnd = upper;
		
		lastPort = uniform(portStart, portEnd);
	}
	
	/+/**
	 * Send a resource (typically a file) to the given user.
	 *
	 * The associated IRC client must be connected.
	 */
	void send(in char[] nick, DccConnection resource)
	{
		enforce(client.connected, "client must be connected before using DCC SEND");
		
		auto port = 0;
		auto len = 0;
		
		auto query = format("SEND %s %d %d %d",
		    resource.name, clientAddress, port, len);
		
		client.ctcpQuery(nick, "DCC", query);
	}+/
	
	/**
	 * Invite the given user to a DCC chat session.
	 *
	 * The associated IRC client must be connected.
	 * Params:
	 *   nick = _nick of user to invite
	 *   timeout = time in seconds to wait for the
	 *   invitation to be accepted
	 * Returns:
	 *   A listening DCC chat session object
	 */
	DccChat inviteChat(in char[] nick, uint timeout = 10)
	{
		enforce(client.connected, "client must be connected before using DCC CHAT");
		
		auto results = allocatePort();
		auto socket = results[0];
		auto port = results[1];
		
		client.ctcpQuery(nick, "DCC",
		    format("CHAT chat %d %d", clientAddress, port));
		
		socket.listen(1);
		
		auto dccChat = new DccChat(socket, timeout);
		dccChat.eventLoop = eventLoop;
		dccChat.eventIndex = eventLoop.add(dccChat);
		return dccChat;
	}
	
	void closeConnection(DccConnection conn)
	{
		eventLoop.remove(conn.eventIndex);
		conn.socket.close();
	}
}

/// Represents a DCC connection.
abstract class DccConnection
{
	public:
	/// Current state of the connection.
	enum State
	{
		preConnect, /// This session is waiting for a connection.
		timedOut, /// This session timed out when waiting for a connection.
		connected, /// This is an active connection.
		closed /// This DCC session has ended.
	}
	
	/// Ditto
	State state = State.preConnect;
	
	private:
	IrcEventLoop eventLoop;
	
	package:
	Socket socket; // Refers to either a server or client
	DccEventIndex eventIndex;
	
	enum Event { none, connectionEstablished, finished }
	
	final Event read()
	{
		final switch(state) with(State)
		{
			case preConnect:
				auto conn = socket.accept();
				socket.close();
				
				socket = conn;
				state = connected;
				
				onConnected();
				
				return Event.connectionEstablished;
			case connected:			
				static ubyte[1024] buffer; // TODO
				
				auto received = socket.receive(buffer);
				if(received <= 0)
				{
					state = closed;
					onDisconnected();
					return Event.finished;
				}
				
				auto data = buffer[0 .. received];
				
				bool finished = onRead(data);
				
				if(finished)
				{
					state = closed;
					socket.close();
					onDisconnected();
					return Event.finished;
				}
				break;
			case closed, timedOut:
				assert(false);
		}
		
		return Event.none;
	}
	
	final void doTimeout()
	{
		state = State.timedOut;
		socket.close();
		
		foreach(callback; onTimeout)
			callback();
	}
	
	protected:
	/**
	 * Initialize a DCC resource with the given _socket, timeout value and state.
	 */
	this(Socket socket, uint timeout, State initialState)
	{
		this.state = initialState;
		this.timeout = timeout;
		this.socket = socket;
	}
	
	/**
	 * Write to this connection.
	 */
	final void write(in void[] data)
	{
		socket.send(data);
	}
	
	/**
	 * Invoked when the connection has been established.
	 */
	abstract void onConnected();
	
	/**
	 * Invoked when the connection was closed cleanly.
	 */
	abstract void onDisconnected();
	
	/**
	 * Invoked when _data was received.
	 */
	abstract bool onRead(in void[] data);
	
	public:
	/// The _timeout value of this connection in seconds.
	immutable uint timeout;
	
	/// Name of this resource.
	abstract string name() @property;
	
	/**
	 * Invoked when an error occurs.
	 */
	void delegate(Exception e)[] onError;
	
	/**
	 * Invoked when a listening connection has timed out.
	 */
	 void delegate()[] onTimeout;
}

/// Represents a DCC chat session.
class DccChat : DccConnection
{
	private:
	import irc.linebuffer;
	
	char[] buffer; // TODO: use dynamically expanding buffer?
	LineBuffer lineBuffer;
	
	this(Socket server, uint timeout)
	{
		super(server, timeout, State.preConnect);
		
		buffer = new char[2048];
		lineBuffer = LineBuffer(buffer, &handleLine);
	}
	
	protected:
	void handleLine(in char[] line)
	{
		foreach(callback; onMessage)
			callback(line);
	}
	
	override void onConnected()
	{
		foreach(callback; onConnect)
			callback();
	}
	
	override void onDisconnected()
	{
		foreach(callback; onFinish)
			callback();
	}
	
	override bool onRead(in void[] data)
	{
		auto remaining = cast(const(char)[])data;
		
		while(!remaining.empty)
		{
			auto space = buffer[lineBuffer.position .. $];
			
			auto len = min(remaining.length, space.length);
			
			space[0 .. len] = remaining[0 .. len];
			
			lineBuffer.commit(len);
			
			remaining = remaining[len .. $];
		}
		
		return false;
	}
	
	public:
	/// Always the string "chat".
	override string name() @property { return "chat"; }
	
	/// Invoked when the session has started.
	void delegate()[] onConnect;
	
	/// Invoked when the session has cleanly ended.
	void delegate()[] onFinish;
	
	/// Invoked when a line of text has been received.
	void delegate(in char[] line)[] onMessage;
	
	/**
	 * Send a single chat _message.
	 * Params:
	 *   message = _message to _send. Must not contain newlines.
	 */
	void send(in char[] message)
	{
		write(message);
		write("\n"); // TODO: worth avoiding?
	}
	
	/**
	 * Send a single, formatted chat message.
	 * Params:
	 *   fmt = format of message to send. Must not contain newlines.
	 *   fmtArgs = $(D fmt) is formatted with these arguments.
	 * See_Also:
	 *   $(STDREF format, formattedWrite)
	 */
	void sendf(FmtArgs...)(in char[] fmt, FmtArgs fmtArgs)
	{
		write(format(fmt, fmtArgs)); // TODO: reusable buffer
		write("\n"); // TODO: worth avoiding?
	}
	
	/**
	 * Send chat _messages.
	 * Each message must be terminated with the character $(D \n).
	 */
	void sendMultiple(in char[] messages)
	{
		write(messages);
	}
	
	/**
	 * End the chat session.
	 */
	void finish()
	{
		socket.close();
		eventLoop.remove(eventIndex);
		
		foreach(callback; onFinish)
			callback();
	}
}
