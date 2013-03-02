module irc.clientset;

import irc.client;

import std.array;
import std.exception;
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
class IrcClientSet
{
	private:
	static struct Watcher
	{
		ev_io io; // Must be first.
		IrcClientSet set;
		IrcClient client;
	}
	
	Watcher[IrcClient] watchers;
	ev_loop_t* ev;
	
	public:
	/**
	 * Create a new $(D IrcClientSet).
	 * Returns:
	 *   New client set.
	 */
	this()
	{
		this.ev = ev_loop_new(EVFLAG_AUTO);
	}
	
	~this()
	{
		foreach(_, ref watcher; watchers)
			ev_io_stop(ev, &watcher.io);

		ev_loop_destroy(ev);
	}
	
	private extern(C) static void callback(ev_loop_t* ev, ev_io* io, int revents)
	{
		auto watcher = cast(Watcher*)io;
		auto client = watcher.client;
		auto set = watcher.set;
		
		bool wasClosed = true;
		
		scope(exit)
		{
			if(wasClosed)
				set.remove(client);
		}
		
		if(set.onError.empty) // Doesn't erase stacktrace this way
			wasClosed = client.read();
		else
		{
			try wasClosed = client.read();
			catch(Exception e)
			{
				foreach(handler; set.onError)
					handler(client, e);
			}
		}
	}
	
	/**
	 * Invoked when an error occurs for a client
	 * in the set.
	 *
	 * If no handlers are registered,
	 * the error will be propagated out of
	 * $(MREF IrcClientSet.run). The client
	 * will always be removed from the set.
	 * Throwing from a handler is allowed but
	 * will cause any subsequent registered handlers
	 * not to be called.
	 */
	void delegate(IrcClient, Exception)[] onError;
	
	/**
	 * Add a connected _client to the set, or do nothing
	 * if the _client is already in the set.
	 *
	 * The _client is automatically removed
	 * if it is disconnected inside an event
	 * callback registered on the the _client.
	 * If the _client is disconnected outside
	 * the event loop, it is the caller's
	 * responsibility to call $(MREF IrcClientSet.remove).
	 * Params:
	 *   client = _client to add
	 * Throws:
	 *   $(DPREF client, UnconnectedClientException) if client is not connected.
	 */
	void add(IrcClient client)
	{
		enforceEx!UnconnectedClientException(
		    client.connected, "client to be added must be connected");

		if(client in watchers)
			return;
		
		watchers[client] = Watcher();
		auto watcher = client in watchers;
		watcher.set = this;
		watcher.client = client;
		
		version(Windows)
		{
			auto handle = _open_osfhandle(client.socket.handle, 0);
			assert(handle != -1);
		}
		else
			auto handle = client.socket.handle;
		
		ev_io_init(&watcher.io, &callback, handle, EV_READ);
		ev_io_start(ev, &watcher.io);
	}
	
	/**
	 * Remove a _client from the set, or do nothing if the _client is not in the set.
	 * Params:
	 *   client = _client to remove
	 */
	void remove(IrcClient client)
	{
		if(auto watcher = client in watchers)
		{
			ev_io_stop(ev, &watcher.io);
			watchers.remove(client);
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