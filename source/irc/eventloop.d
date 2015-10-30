module irc.eventloop;

import irc.client;
import irc.dcc : DccConnection;
import irc.exception;
import irc.util : alloc, dealloc;

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

	extern(C) int _open_osfhandle(intptr_t osfhandle, int flags) nothrow;

	// Dirk doesn't use this, just makes the linker happy
	extern(C) void* _stati64;
}

private int getHandle(Socket socket)
{
	version(Windows)
	{
		auto handle = _open_osfhandle(socket.handle, 0);
		assert(handle != -1);
	}
	else
		auto handle = socket.handle;

	return handle;
}

//package alias IrcEventLoop.DccWatcher* DccEventIndex; // DMD bug?
package alias void* DccEventIndex;

/**
 * A collection of $(DPREF client, IrcClient) objects for efficiently handling incoming data.
 */
class IrcEventLoop
{
	private:
	static struct Watcher
	{
		ev_io io; // Must be first.
		IrcEventLoop eventLoop;
	}

	static struct DccWatcher
	{
		Watcher watcher;
		alias watcher this;

		ev_timer timeoutTimer;
		ubyte[4] _padding; // emplace??

		DccWatcher* _next, _prev;
	}

	ev_loop_t* ev;
	Watcher[IrcClient] watchers;
	DccWatcher* dccWatchers;

	ev_idle idleWatcher;
	void delegate()[] customMessages;

	public:
	/**
	 * Create a new event loop.
	 */
	this()
	{
		this.ev = ev_loop_new(EVFLAG_AUTO);
	}

	~this()
	{
		if(ev_is_active(&idleWatcher))
			ev_idle_stop(ev, &idleWatcher);

		foreach(_, ref watcher; watchers)
			ev_io_stop(ev, &watcher.io);

		ev_loop_destroy(ev);

		for(auto watcher = dccWatchers; watcher != null;)
		{
			ev_io_stop(ev, &watcher.io);

			auto next = watcher._next;
			dealloc(watcher);
			watcher = next;
		}
	}

	private extern(C) static void callback(ev_loop_t* ev, ev_io* io, int revents)
	{
		auto client = cast(IrcClient)io.data;
		auto eventLoop = (cast(Watcher*)io).eventLoop;

		bool wasClosed = true;

		scope(exit)
		{
			if(wasClosed)
				eventLoop.remove(client);
		}

		if(eventLoop.onError.empty) // Doesn't erase stacktrace this way
			wasClosed = client.read();
		else
		{
			try wasClosed = client.read();
			catch(Exception e)
			{
				foreach(handler; eventLoop.onError)
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
	 * $(MREF IrcEventLoop.run). The client
	 * will always be removed from the set.
	 * Throwing from a handler is allowed but
	 * will cause any subsequent registered handlers
	 * not to be called and the exception will
	 * keep propagating.
	 */
	void delegate(IrcClient, Exception)[] onError;

	/**
	 * Add a connected _client to the set, or do nothing
	 * if the _client is already in the set.
	 *
	 * The _client is automatically removed
	 * if it is disconnected inside an event
	 * callback registered on the _client.
	 * If the _client is disconnected outside
	 * the event loop, it is the caller's
	 * responsibility to call $(MREF IrcEventLoop.remove).
	 * Params:
	 *   client = _client to _add
	 * Throws:
	 *   $(DPREF exception, UnconnectedClientException) if client is not connected.
	 */
	void add(IrcClient client)
	{
		enforceEx!UnconnectedClientException(
		    client.connected, "client to be added must be connected");

		if(client in watchers)
			return;

		watchers[client] = Watcher();
		auto watcher = client in watchers;
		watcher.io.data = cast(void*)client;
		watcher.eventLoop = this;

		ev_io_init(&watcher.io, &callback, getHandle(client.socket), EV_READ);
		ev_io_start(ev, &watcher.io);
	}

	/*
	 * DCC events
	 */
	private extern(C) static void dccCallback(ev_loop_t* ev, ev_io* io, int revents)
	{
		auto dcc = cast(DccConnection)io.data;
		auto watcher = cast(DccWatcher*)io;
		auto eventLoop = watcher.eventLoop;

		DccConnection.Event dccEvent;

		try dccEvent = dcc.read();
		catch(Exception e)
		{
			eventLoop.remove(dcc.eventIndex);

			foreach(callback; dcc.onError)
				callback(e);

			return;
		}

		final switch(dccEvent) with(DccConnection.Event)
		{
			case none:
				break;
			case connectionEstablished: // dcc.socket should now contain client
				ev_timer_stop(ev, &watcher.timeoutTimer);
				ev_io_stop(ev, io);
				ev_io_set(io, getHandle(dcc.socket), EV_READ);
				ev_io_start(ev, io);
				break;
			case finished:
				eventLoop.remove(dcc.eventIndex);
				break;
		}
	}

	private extern(C) static void dccTimeout(ev_loop_t* ev, ev_timer* timer, int revents)
	{
		auto dcc = cast(DccConnection)timer.data;
		auto watcher = cast(DccWatcher*)dcc.eventIndex;
		auto eventLoop = watcher.eventLoop;

		scope(exit) eventLoop.remove(watcher);

		dcc.doTimeout();
	}

	package DccEventIndex add(DccConnection conn)
	{
		auto watcher = alloc!DccWatcher();
		watcher.io.data = cast(void*)conn;
		watcher.timeoutTimer.data = cast(void*)conn;
		watcher.eventLoop = this;

		ev_io_init(&watcher.io, &dccCallback, getHandle(conn.socket), EV_READ);
		ev_io_start(ev, &watcher.io);

		ev_timer_init(&watcher.timeoutTimer, &dccTimeout, conn.timeout, 0);
		ev_timer_start(ev, &watcher.timeoutTimer);

		auto prevHead = dccWatchers;
		dccWatchers = watcher;

		watcher._next = prevHead;
		if(prevHead) prevHead._prev = watcher;

		return watcher;
	}

	package void remove(DccEventIndex dccEvent)
	{
		DccWatcher* watcher = cast(DccWatcher*)dccEvent;

		auto prev = watcher._prev;
		auto next = watcher._next;

		ev_io_stop(ev, &watcher.io);
		dealloc(watcher);

		if(prev) prev._next = next;
		if(next) next._prev = prev;

		if(dccWatchers == watcher)
			dccWatchers = null;
	}

	/**
	 * Remove a _client from the set, or do nothing if the _client is not in the set.
	 * Params:
	 *   client = _client to _remove
	 */
	void remove(IrcClient client)
	{
		if(auto watcher = client in watchers)
		{
			ev_io_stop(ev, &watcher.io);
			watchers.remove(client);
		}
	}

	// Idle events
	private extern(C) static void onIdle(ev_loop_t* ev, ev_idle* watcher, int revents)
	{
		auto eventLoop = (cast(IrcEventLoop)watcher.data);

		while(!eventLoop.customMessages.empty)
		{
			auto cb = eventLoop.customMessages.front;
			eventLoop.customMessages.popFront();
			cb();
		}

		ev_idle_stop(ev, watcher);
	}

	/**
	 * Run the specified callback at the next idle event.
	 */
	void post(void delegate() callback)
	{
		customMessages ~= callback;

		auto watcher = &idleWatcher;

		if(!ev_is_active(watcher))
		{
			watcher.data = cast(void*)this;
			ev_idle_init(watcher, &onIdle);
			ev_idle_start(ev, watcher);
		}
	}

	private static struct CustomTimer
	{
		ev_timer timer;
		void delegate() callback;
	}

	private extern(C) static void onCustomTimeout(ev_loop_t* ev, ev_timer* timer, int revents)
	{
		import core.memory : GC;
		auto customTimer = cast(CustomTimer*)timer;

		//scope(exit) dealloc(customTimer);

		if(customTimer.timer.repeat == 0)
			GC.removeRoot(timer);

		customTimer.callback();
	}

	enum TimerRepeat { yes, no }

	struct Timer
	{
		private:
		IrcEventLoop eventLoop;
		CustomTimer* timer;

		public:
		void stop()
		{
			enforce(active);
			ev_timer_stop(eventLoop.ev, &timer.timer);
			timer = null;
		}

		bool active() @property
		{
			return timer !is null && ev_is_active(&timer.timer);
		}

		TimerRepeat repeat() @property
		{
			enforce(active);
			with(TimerRepeat) return timer.timer.repeat == 0? no : yes;
		}

		bool opCast(T)() if(is(T == bool))
		{
			return active;
		}
	}

	/**
	* Run the specified callback as soon as possible after $(D time)
	* has elapsed.
	*
	* Equivalent to $(D postTimer(callback, time, TimerRepeat.no)).
	*/
	Timer post(void delegate() callback, double time)
	{
		return postTimer(callback, time, TimerRepeat.no);
	}

	/**
	 * Run $(D callback) at every $(D interval), or just once after $(D interval)
	 * time has elapsed if $(D repeat) is $(D TimerRepeat.no).
	 */
	Timer postTimer(void delegate() callback, double interval, TimerRepeat repeat)
	{
		import core.memory : GC;

		enforce(callback);
		enforce(interval >= 0);

		//auto watcher = alloc!CustomTimer(); // TODO: use more efficient memory management
		auto watcher = new CustomTimer();
		watcher.callback = callback;

		double repeatTime = repeat == TimerRepeat.yes? interval : 0.0;

		ev_timer_init(&watcher.timer, &onCustomTimeout, interval, repeatTime);
		ev_timer_start(ev, &watcher.timer);

		GC.addRoot(watcher);

		return Timer(this, watcher);
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