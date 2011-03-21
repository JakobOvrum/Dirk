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
	IrcClient client;
	
	this(IrcClient client, string message)
	{
		super(message);
		this.client = client;
	}
}

class IrcClient
{
	private:
	string m_nick = "dirkuser";
	string m_user = "dirk";
	string m_name = "dirk";
	InternetAddress m_address = null;
	char[1024] lineBuffer;
	
	package:
	Socket socket = null;

	public:
	void connect(InternetAddress addr)
	{
		socket = new TcpSocket(addr);
		m_address = addr;
		
		write("USER %s * * :%s", userName, realName);
		write("NICK %s", nick);
	}
	
	IrcLine parsedLine;
	
	//TODO: use ringbuffer
	void read()
	{
		auto rawline = simpleReadLine();
		
		debug(Dirk) writefln(`>> "%s"`, rawline);
		
		enforce(parse(rawline, parsedLine), new Exception("error parsing line"));
		
		handle(parsedLine);
	}
	
	private const(char)[] simpleReadLine()
	{
		char c = 0;
		char[] buffer = (&c)[0..1];
		
		size_t len = 0;
		
		while(c != '\n')
		{
			auto received = socket.receive(buffer);
		
			if(received == Socket.ERROR)
			{
				throw new Exception("Socket read operation failed");
			}
			else if(received == 0)
			{
				debug(Dirk) writeln("Remote ended connection");
				socket.close();
				return null;
			}
			
			lineBuffer[len++] = c;
		}
		
		if(len > 1 && lineBuffer[len - 2] == '\r')
		{
			--len;
		}
		
		return lineBuffer[0 .. len - 1];
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
	
	@property InternetAddress serverAddress()
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
				write("NICK %s\r\n", nick);
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
	
	void quit(string message)
	{
		write("QUIT :%s", message);
		socket.close();
	}
	
	void delegate()[] onConnect;
	void delegate(IrcUser user, in char[] channel, in char[] message)[] onMessage;
	void delegate(IrcUser user, in char[] channel, in char[] message)[] onNotice;
	const(char)[] delegate(in char[] newnick)[] onNickInUse;
	
	protected:
	IrcUser getUser(const(char)[] prefix)
	{
		return parseUser(prefix);
	}
	
	private:
	void fireEvent(T, U...)(T event, U args)
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
				write("PONG :%s", line.parameters[0]);
				break;
			case "433":
				bool handled = false;
				
				foreach(cb; onNickInUse)
				{
					if(auto newNick = cb(line.parameters[1]))
					{
						write("NICK %s", newNick);
						handled = true;
						break;
					}
				}
				
				if(!handled)
				{
					socket.close();
					throw new Exception(`"Nick already in use" was unhandled`);
				}
				break;
			case "PRIVMSG":
				fireEvent(onMessage, getUser(line.prefix), line.parameters[0], line.parameters[1]);
				break;
			case "NOTICE":
				fireEvent(onNotice, getUser(line.prefix), line.parameters[0], line.parameters[1]);
				break;
			case "ERROR":
				throw new IrcErrorException(this, line.parameters[0].idup);
			case "001":
				fireEvent(onConnect);
				break;
			default:
				debug(Dirk) writefln(`Unhandled command "%s"`, line.command);
				break;
		}
	}
}