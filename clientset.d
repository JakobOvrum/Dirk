module irc.clientset;

import irc.client;

import std.socket;

struct IrcClientSet
{
	private:
	IrcClient[] clients;
	SocketSet set;
	
	void remove(size_t i)
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
			throw new Exception("clients in IrcClientSet must be connected");
		}
		else if(!set.isSet(client.socket))
		{
			set.add(client.socket);
			clients ~= client;
		}
	}
	
	void remove(IrcClient client)
	{
		foreach(i, cl; clients)
		{
			if(cl == client)
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
			foreach(client; clients)
			{
				if(!set.isSet(client.socket))
					set.add(client.socket);
			}
			
			int eventCount = Socket.select(set, null, null, null);
			if(eventCount != 0)
			{
				size_t handled = 0;
				for(size_t i = 0; i < clients.length; ++i)
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