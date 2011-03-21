module irc.clientset;

import irc.client;

import std.socket;

class IrcClientSet
{
	private:
	IrcClient[] clients;
	SocketSet set;
	
	void remove(int i)
	{
		clients[i] = clients[$ - 1];
		clients.length = clients.length - 1;
	}
	
	public:
	this(uint max = 64)
	{
		set = new SocketSet(max);
	}
	
	void add(IrcClient client)
	{
		if(!client.connected)
		{
			throw new Exception("clients in ClientSet must be connected");
		}
		else if(!set.isSet(client.socket))
		{
			set.add(client.socket);
			clients ~= client;
		}
	}
	
	void remove(IrcClient client)
	{
		for(int i = 0; i < clients.length; ++i)
		{
			if(clients[i] == client)
			{
				remove(i);
				break;
			}
		}
	}
	
	void run()
	{
		while(clients.length > 0)
		{
			int eventCount = Socket.select(set, null, null, null);
			if(eventCount != 0)
			{
				int handled = 0;
				for(int i = 0; i < clients.length; ++i)
				{
					IrcClient client = clients[i];
					if(set.isSet(client.socket))
					{
						client.read();
						if(!client.connected)
							remove(i);
						
						if(++handled == eventCount)
							break;
					}
				}
			}
		}
	}
}