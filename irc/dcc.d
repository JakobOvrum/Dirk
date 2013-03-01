module irc.dcc;

import std.algorithm;
import std.array;
import std.exception;
import std.random : uniform;
import std.range;
import std.socket;
import std.stdio;

import irc.protocol;
import irc.client;

//ffs
version(Windows)
	import std.c.windows.winsock;
else version(posix)
	import core.sys.posix.netinet.in_;
else
	static assert(false, "ffff");

///
enum DccChatType
{
	plain, ///
	secure ///
}

class DccException : Exception
{
	this(string msg, Throwable next = null, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line, next);
	}
}

///
class DccServer
{
	private:
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
	
	Socket allocatePort()
	{
		auto portRange = iota(portStart, portEnd + 1);
		
		auto ports = portRange.cycle(lastPort);
		ports.popFront(); // skip last used port
		
		size_t tries = 0;
		auto socket = new TcpSocket();
		foreach(port; ports)
		{
			try 
			{
				auto addr = new InternetAddress(cast(ushort)port); // ew :<
				socket.bind(addr);
				return socket;
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
		if(clientAddress != 0)
		{
			client.onUserhostReply.unregisterHandler(&onUserhostReply);
			return;
		}
		
		foreach(ref user; users)
		{
			if(user.nick == queriedNick)
			{
				clientAddress = user.hostName;
				client.onUserhostReply.unregisterHandler(&onUserhostReply);
				break;
			}
		}
	}
	
	public:
	/**
	 * Create a new DCC server given the IRC client
	 * to be associated with this server.
	 *
	 * The associated IRC client is used to send
	 * DCC/CTCP notifications as well as to look up
	 * the Internet address to advertise for this
	 * server.
	 */
	this(IrcClient client)
	{
		this.client = client;
		
		setPortRange(49152, 65535);
		
		if(client.connected)
			queryUserhost();
		else
		{
			void onConnect()
			{
				queryUserhost();
				client.onConnect.unregisterHandler(&onConnect);
			}
			
			client.onConnect ~= &onConnect;
		}
	}
	
	/**
	 * The IP address of the DCC server in network-byte order.
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
		clientAddress = (cast(sockaddr_in*)address.name).sin_addr.s_addr;
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
	
	/**
	 * Offer a resource to the given user.
	 *
	 * The associated client must be connected.
	 */
	void send(in char[] nick, DccResource resource)
	{
		enforce(client.connected, "client must be connected before using DCC SEND");
		
		auto port = 0;
		auto len = 0;
		
		auto query = format("SEND %s %d %d %d",
		    resource.name, clientAddress, port, len);
		
		client.ctcpQuery(nick, "DCC", query);
	}
	
	/**
	 * Open a DCC chat connection with the given user.
	 *
	 * The associated client must be connected.
	 */
	void openChat(in char[] nick, void delegate(DccChat) onConnected)
	{
		enforce(client.connected, "client must be connected before using DCC CHAT");
		
		/+
		auto listener = allocatePort();
		
		client.ctcpQuery(nick, "DCC",
		    format("CHAT chat %d %d", clientAddress, listener.port));
		
		listener.listen(1);
		+/
	}
}

interface DccResource
{
	public:
	string name() @property;
	
	protected:
	void onConnected(Socket socket);
}

class DccChat : DccResource
{
	private:
	Socket socket;
	ConnectedCallback onChatStart;
	
	this(ConnectedCallback onChatStart)
	{
		this.onChatStart = onChatStart;
	}
	
	protected:
	void onConnected(Socket socket)
	{
		this.socket = socket;
		onChatStart(this);
	}
	
	public:
	~this()
	{
		close();
	}
	
	string name() @property { return "chat"; }
	
	///
	alias void delegate(DccChat) ConnectedCallback;
	
	/**
	 * Send chat messages.
	 * Each message must be terminated with the sequence $(D \r\n).
	 */
	void send(in char[] messages)
	{
		socket.send(messages);
	}
	
	/**
	 * End the chat connection.
	 */
	void close()
	{
		socket.close();
	}
}
