module irc.clientset;

import irc.client;

import std.socket;

// libev is a world of pain on Windows - where it just
// uses select() internally anyway - but it pays off on
// other platforms.
import deimos.ev;

version(Windows)
{
	import core.stdc.stdint : intptr_t;
	
	extern(C) int _open_osfhandle(intptr_t osfhandle, int flags);
	
	// Dirk doesn't use this, just makes the linker happy
	extern(C) void* _stati64;
}

/**
 * A collection of $(DPREF client, IrcClient) objects for efficiently handling incoming data.
 */
struct IrcClientSet
{
	private:
	size_t[IrcClient] indexes;
	ev_io[] watchers;
	ev_loop_t* ev;
	
	ev_io* allocateWatcher()
	{
		++watchers.length;
		return &watchers[$ - 1];
	}
	
	void remove(size_t i)
	{
		auto lastSlot = &watchers[$ - 1];
		auto removeSlot = &watchers[i];
		
		ev_io_stop(ev, removeSlot);
		
		if(removeSlot != lastSlot)
		{
			ev_io_stop(ev, lastSlot);
			*removeSlot = *lastSlot;
			indexes[cast(IrcClient)removeSlot.data] = i;
			ev_io_start(ev, removeSlot);
		}
		
		--watchers.length;
	}
	
	this(ev_loop_t* ev)
	{
		this.ev = ev;
	}
	
	public:
	@disable this();
	@disable this(this);
	
	~this()
	{
		foreach(ref ev_io; watchers)
			ev_io_stop(ev, &ev_io);
		
		watchers = null;
		ev_loop_destroy(ev);
	}
	
	/**
	 * Create a new $(D IrcClientSet).
	 * Returns:
	 *   New client set.
	 */
	static IrcClientSet create()
	{
		return IrcClientSet(ev_loop_new(EVFLAG_AUTO));
	}
	
	private extern(C) static void callback(ev_loop_t* ev, ev_io* io, int revents)
	{
		auto client = cast(IrcClient)io.data;
		client.read();
	}
	
	/**
	 * Add a connected _client to the set.
	 * Params:
	 *   client = _client to add
	 * Throws:
	 *   $(DPREF client, UnconnectedClientException) if client is not connected.
	 */
	void add(IrcClient client)
	{
		if(!client.connected)
			throw new UnconnectedClientException("clients in IrcClientSet must be connected");

		if(client in indexes)
			return;
		
		auto io = allocateWatcher();
		io.data = cast(void*)client;
		indexes[client] = watchers.length - 1;
		
		version(Windows)
		{
			auto handle = _open_osfhandle(client.socket.handle, 0);
			assert(handle != -1);
		}
		else
			auto handle = client.socket.handle;
		
		ev_io_init(io, &callback, handle, EV_READ);
		ev_io_start(ev, io);
	}
	
	/**
	 * Remove a _client from the set, or do nothing if the _client is not in the set.
	 * Params:
	 *   client = _client to remove
	 */
	void remove(IrcClient client)
	{
		if(auto index = client in indexes)
		{
			indexes.remove(client);
			remove(*index);
		}
	}
	
	/**
	 * Handle incoming data for the clients in the set.
	 *
	 * The incoming data is handled by the respective client,
	 * and callbacks are called.
	 * Returns when all clients are no longer connected,
	 * or immediately if there are no clients in the set.
	 */
	void run()
	{
		ev_run(ev, 0);
	}
}