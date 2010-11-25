module irc.client;

import irc.protocol;

class IrcConnectException : Exception
{
	this(string message)
	{
		super(message);
	}
}

abstract class IrcClient
{
	private:
	string m_nick = "dirkuser";
	string m_user = "dirk";
	string m_name = "dirk";
	bool m_connected = false;
	
	public:
	void connect(InternetAddress addr)
	{
	}
	
	void recieve()
	{
	}
	
	void write(in char[] rawline)
	{
		if(!connected)
			throw new Exception("cannot write to unconnected IRC connection");
	}
	
	void send(in char[] channel, in char[] message)
	{
	}
	
	bool connected() @property
	{
		return m_connected;
	}
	
	@property
	{
		string realName()
		{
			return m_user;
		}
		
		void realName(string realName)
		{
			enforce(realName !is null && realName.length != 0);
			if(connected)
				throw Exception("Cannot change real name while connected");
			else
				m_real = realName;
		}
	}
	
	@property
	{
		string userName()
		{
			return m_user;
		}
		
		void userName(string userName)
		{
			enforce(userName !is null && userName.length != 0);
			if(connected)
				throw Exception("Cannot change user-name while connected");
			else
				m_user = userName;
		}
	}
	
	@property
	{
		string nick()
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
		write(format("JOIN %s\r\n", channel));
	}
	
	void part(string channel)
	{
		write(format("PART %s\r\n", channel));
	}
	
	protected:
	void onMessage(IrcUser user, in char[] channel, in char[] message){}
	
	private:
	void handle(IrcLine line)
	{
		switch(line.command)
		{
			case "PRIVMSG":
				auto user = getUser(line.prefix);
				onMessage(user, line.parameters[0], line.parameters[1]);
			default:
				break;
		}
	}
}