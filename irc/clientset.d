module irc.clientset;

import irc.client;

import std.socket;

/**
 * A collection of IrcClient objects for efficiently handling incoming data.
 */
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
	
	this(SocketSet set)
	{
		this.set = set;
	}
	
	public:
	@disable this();
	
	/**
	 * Create a new IrcClientSet with the specified size.
	 * Params:
	 *   max = _max numbers of clients this set can hold
	 * Returns:
	 *   New client set.
	 */
	static IrcClientSet create(uint max = 64)
	{
		return IrcClientSet(new SocketSet(max));
	}
	
	/**
	 * Add a connected client to the set.
	 * Params:
	 *   client = _client to add
	 * Throws:
	 *   UnconnectedClientException if client is not connected.
	 */
	void add(IrcClient client)
	{
		if(!client.connected)
		{
			throw new UnconnectedClientException("clients in IrcClientSet must be connected");
		}
		else if(!set.isSet(client.socket))
		{
			set.add(client.socket);
			clients ~= client;
		}
	}
	
	/**
	 * Remove a client from the set, or do nothing if the client is not in the set.
	 * Params:
	 *   client = _client to remove
	 */
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
	
	/**
	 * Handle incoming data for the clients in the set.
	 *
	 * The incoming data is handled by the respective client,
	 * and callbacks are called.
	 * Returns when all clients are no longer connected,
	 * or immediately if no there are no clients in the set.
	 */
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