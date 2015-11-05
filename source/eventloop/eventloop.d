module eventloop.eventloop;

import eventloop.interfaces;

import core.time;

import std.exception : enforce;
import std.experimental.allocator : make, dispose;
import std.experimental.allocator.mallocator;
import std.experimental.allocator.building_blocks.free_list;
import std.socket : Socket;

// libev is a world of pain on Windows - where it just
// uses select() internally anyway - but it pays off on
// other platforms.
import deimos.ev;

version(Windows)
{
	import core.stdc.stdint : intptr_t;

	extern(C) int _open_osfhandle(intptr_t osfhandle, int flags) nothrow @nogc;

	// Dirk doesn't use this, just makes the linker happy
	extern(C) void* _stati64;
}

private int getHandle(Socket socket) nothrow @trusted @nogc
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

/**
 * A collection of $(DPREF client, IrcClient) objects for efficiently handling incoming data.
 */
class EventLoop
{
	private:
	struct Watcher
	{
		ev_io io;
		EventLoop eventLoop;
		Watcher* next;
	}

	ev_loop_t* ev;
	FreeList!(Mallocator, Watcher.sizeof) watcherAllocator;
	Watcher* watchers;

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

		for(auto watcher = watchers; watcher;)
		{
			ev_io_stop(ev, &watcher.io);
			auto next = watcher.next;
			watcherAllocator.dispose(watcher);
			watcher = next;
		}

		ev_loop_destroy(ev);
	}

	private extern(C) static void onReady(ev_loop_t* ev, ev_io* io, int revents)
	{
		import std.range.primitives;

		auto client = cast(SocketReady)io.data;
		auto watcher = cast(Watcher*)io;
		auto eventLoop = watcher.eventLoop;

		bool wasClosed = true;

		scope(exit)
		{
			if(wasClosed)
				eventLoop.remove(client);
		}

		if(eventLoop.onError.empty) // Doesn't erase stacktrace this way
			wasClosed = client.onReady();
		else
		{
			try wasClosed = client.onReady();
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
	void delegate(SocketReady, Exception)[] onError;

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
	void add(SocketReady client)
	{
		version(none) enforceEx!UnconnectedClientException(
		    client.connected, "client to be added must be connected");

		auto prevFirst = watchers;
		watchers = watcherAllocator.make!Watcher();
		watchers.io.data = cast(void*)client;
		watchers.eventLoop = this;
		watchers.next = prevFirst;

		auto eventType = client.eventType;
		int evEvents = 0;

		if(eventType & SocketReady.EventType.read)
			evEvents |= EV_READ;

		if(eventType & SocketReady.EventType.write)
			evEvents |= EV_WRITE;

		ev_io_init(&watchers.io, &onReady, getHandle(client.socket), evEvents);
		ev_io_start(ev, &watchers.io);
	}

	/**
	 * Remove a _client from the set, or do nothing if the _client is not in the set.
	 * Params:
	 *   client = _client to _remove
	 */
	void remove(SocketReady client)
	{
		if(client == cast(SocketReady)watchers.io.data)
		{
			ev_io_stop(ev, &watchers.io);
			watcherAllocator.dispose(watchers);
			watchers = null;
			return;
		}

		for(auto cur = watchers; cur; cur = cur.next)
		{
			auto next = cur.next;
			if(client == cast(SocketReady)next.io.data)
			{
				ev_io_stop(ev, &next.io);
				cur.next = next.next;
				watcherAllocator.dispose(next);
			}
		}
	}

	// Idle events
	private extern(C) static void onIdle(ev_loop_t* ev, ev_idle* watcher, int revents)
	{
		import std.range.primitives;

		auto eventLoop = cast(EventLoop)watcher.data;

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

	private struct CustomTimer
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
		EventLoop eventLoop;
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
	Timer post(void delegate() callback, Duration time)
	{
		return postTimer(callback, time, TimerRepeat.no);
	}

	/**
	 * Run $(D callback) at every $(D interval), or just once after $(D interval)
	 * time has elapsed if $(D repeat) is $(D TimerRepeat.no).
	 */
	Timer postTimer(void delegate() callback, Duration interval, TimerRepeat repeat)
	{
		import core.memory : GC;

		enforce(callback);
		enforce(interval != Duration.zero);
		enforce(!interval.isNegative);

		//auto watcher = alloc!CustomTimer(); // TODO: use more efficient memory management
		auto watcher = new CustomTimer();
		watcher.callback = callback;

		double fInterval = interval.total!"hnsecs" / double(core.time.seconds(1).total!"hnsecs");
		double repeatTime = repeat == TimerRepeat.yes? fInterval : 0.0;

		ev_timer_init(&watcher.timer, &onCustomTimeout, fInterval, repeatTime);
		ev_timer_start(ev, &watcher.timer);

		GC.addRoot(watcher);

		return Timer(this, watcher);
	}

	deprecated("Please use EventLoop.post(void delegate(), Duration)")
	Timer post(void delegate() callback, double time)
	{
		auto dur = hnsecs(cast(long)(time * seconds(1).total!"hnsecs"));
		return post(callback, dur);
	}

	deprecated("Please use EventLoop.postTimer(void delegate(), Duration, TimerRepeat)")
	Timer postTimer(void delegate() callback, double interval, TimerRepeat repeat)
	{
		auto dur = hnsecs(cast(long)(interval * seconds(1).total!"hnsecs"));
		return postTimer(callback, dur, repeat);
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
