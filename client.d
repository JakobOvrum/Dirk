module irc.client;

import irc.protocol;
public import irc.protocol : IrcUser;
import irc.ringbuffer;

import std.socket;
public import std.socket : InternetAddress;

import std.exception;
import std.algorithm;
import std.string : format;
debug(Dirk) import std.stdio;

class IrcErrorException : Exception
{
	this(string message)
	{
		super(message);
	}
}

class IrcClient
{
	private:
	string m_nick = "dirkuser";
	string m_user = "dirk";
	string m_name = "dirk";
	InternetAddress m_address = null;
	Socket socket = null;
	
	RingBuffer* buffer = null;
	char[] parseBuffer = null;
	
	public:
	void connect(InternetAddress addr)
	{
		socket = new TcpSocket(addr);
		m_address = addr;
		
		write("USER %s * * :%s", userName, realName);
		write("NICK %s", nick);
		
		buffer = rb_new(512);
		parseBuffer = new char[512];
	}
	
	~this()
	{
		if(buffer)
			rb_free(buffer);
	}
	
	//TODO: use ringbuffer
	void read()
	{
		auto receivedLen = socket.receive(parseBuffer);
		
		if(receivedLen == Socket.ERROR)
		{
			throw new Exception("Socket read operation failed");
		}
		else if(receivedLen == 0)
		{
			debug(Dirk) writeln("Remote ended connection");
			socket.close();
			return;
		}
		
		
		
		rb_write(buffer, parseBuffer.ptr, receivedLen);
		
		const(char)[] rawline;
		while((rawline = eatLine()) !is null)
		{
			debug(Dirk) writefln(`>> "%s"`, rawline);
				
			IrcLine line;
			enforce(parse(rawline, line), "invalid IRC line");
			handle(line);
		}
	}
	
	const(char)[] eatLine()
	{
		size_t lineLen = 0;
		size_t bufferLen = 0;
		bool wasCr = false;
		foreach(n; 0..2)
		{
			const(char)* p = rb_read_pointer(buffer, lineLen, &bufferLen);
			
			foreach(i; 0..bufferLen)
			{
				lineLen++;
				if(wasCr && p[i] == '\n')
				{
					if(n == 0)
					{
						rb_read_commit(buffer, lineLen);
						return p[0..lineLen - 2];
					}
					else
					{
						rb_read(buffer, parseBuffer.ptr, lineLen);
						return parseBuffer[0..lineLen - 2];
					}
				}
				else
				{
					wasCr = p[i] == '\r';
				}
			}
		}
		return null;
	}
	
	void run()
	{
		while(connected)
			read();
	}
	
	void write(T...)(in char[] rawline, T fmtArgs)
	{
		enforce(connected, new Exception("cannot write to unconnected IRC connection"));
		
		static if(fmtArgs.length == 0)
		{
			debug(Dirk) writefln(`<< "%s"`, rawline);
			socket.send(rawline);
		}
		else
		{
			auto fmtRawline = format(rawline, fmtArgs);
			debug(Dirk) writefln(`<< "%s"`, fmtRawline);
			socket.send(fmtRawline);
		}
			
		socket.send("\r\n");
	}
	
	void send(in char[] channel, in char[] message)
	{
		write("PRIVMSG %s :%s", channel, message);
	}
	
	@property bool connected() const
	{
		return socket !is null && (cast(Socket)socket).isAlive();
	}
	
	@property const(InternetAddress) address() const
	{
		return m_address;
	}
	
	@property
	{
		string realName() const
		{
			return m_user;
		}
		
		void realName(string realName)
		{
			enforce(realName !is null && realName.length != 0);
			enforce(connected, "Cannot change real name while connected");
			m_name = realName;
		}
	}
	
	@property
	{
		string userName() const
		{
			return m_user;
		}
		
		void userName(string userName)
		{
			enforce(userName !is null && userName.length != 0);
			enforce(connected, "Cannot change user-name while connected");
			m_user = userName;
		}
	}
	
	@property
	{
		string nick() const
		{
			return m_nick;
		}
		
		void nick(string nick)
		{
			enforce(nick !is null && nick.length != 0);
			if(connected)
				write(format("NICK %s\r\n", nick));
			else
				m_nick = nick;
		}
	}
	
	void join(string channel)
	{
		write("JOIN %s", channel);
	}
	
	void join(string channel, string key)
	{
		write("JOIN %s :%s", channel, key);
	}
	
	void part(string channel)
	{
		write("PART %s", channel);
	}
	
	void part(string channel, string message)
	{
		write("PART %s :%s", channel, message);
	}
	
	const(char)[] delegate(in char[] newnick)[] onNickInUse;
	void delegate(IrcUser user, in char[] channel, in char[] message)[] onMessage;
	void delegate(IrcUser user, in char[] channel, in char[] message)[] onNotice;
	
	void fireEvent(string event, T...)(T args)
	{
		auto callbacks = mixin("on" ~ event);
		foreach(cb; callbacks)
		{
			cb(args);
		}
	}
	
	protected:
	IrcUser getUser(const(char)[] prefix)
	{
		return parseUser(prefix);
	}
	
	private:
	void handle(IrcLine line)
	{
		switch(line.command)
		{
			case "PING":
				write("PONG :%s", line.parameters[0]);
				break;
			case "433":
				foreach(cb; onNickInUse)
				{
					if(auto newNick = cb(line.parameters[1]))
					{
						write("NICK %s", newNick);
						break;
					}
				}
				break;
			case "PRIVMSG":
				fireEvent!("Message")(getUser(line.prefix), line.parameters[0], line.parameters[1]);
				break;
			case "NOTICE":
				fireEvent!("Notice")(getUser(line.prefix), line.parameters[0], line.parameters[1]);
				break;
			case "ERROR":
				throw new IrcErrorException(line.parameters[0].idup);
			default:
				debug(Dirk) writefln(`Unhandled command "%s"`, line.command);
				break;
		}
	}
}