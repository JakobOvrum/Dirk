// TODO: users/channels API and finish integrity check
module irc.tracker;

import irc.client;
import irc.util : ExceptionConstructor;

import std.exception : enforceEx;
import std.traits : Unqual;
import std.typetuple : TypeTuple;

/// Can be thrown by $(MREF IrcTracker.channels).
class IrcTrackingException : Exception
{
	mixin ExceptionConstructor!();
}

/**
 * Create a new channel and user tracking object for the given
 * $(DPREF _client, IrcClient). Tracking for the new object
 * is disabled; use $(MREF IrcTracker.start) to commence tracking.
 *
 * Bug:
 *    The given $(D client) must not be a member of any channels
 *    when tracking is started. There is an elegant fix for this,
 *    which is planned for the future.
 *
 * See_Also:
 *    $(MREF IrcTracker)
 */
// TODO: Add example
IrcTracker track(IrcClient client)
{
	return new IrcTracker(client);
}

/**
 * Keeps track of all channels and channel members
 * visible to the associated $(DPREF client, IrcClient) connection.
 */
// TODO: mode tracking
class IrcTracker
{
	private:
	IrcClient _client;
	TrackedChannel[string] _channels;
	TrackedUser*[string] _users;
	TrackedUser* thisUser;
	bool _isTracking = false;

	debug(IrcTracker) import std.stdio;

	final:
	debug(IrcTracker) void checkIntegrity()
	{
		import std.algorithm;

		if(!isTracking)
		{
			assert(channels.empty);
			assert(_channels is null);
			assert(_users is null);
			return;
		}

		foreach(channel; channels)
		{
			assert(channel.name.length != 0);
			assert(channel.users.length != 0);
			foreach(member; channel.users)
			{
				auto user = findUser(member.nickName);
				assert(user);
				assert(user == member);
			}
		}

		foreach(user; users)
			if(user.nickName != client.nickName)
				assert(channels.map!(chan => chan.users).joiner().canFind(user));
	}

	void onSuccessfulJoin(in char[] channelName)
	{
		debug(IrcTracker)
		{
			writeln("onmejoin: ", channelName);
			checkIntegrity();
		}

		auto channel = TrackedChannel(channelName.idup);
		channel._users = [client.nickName: thisUser];
		_channels[channel.name] = channel;

		debug(IrcTracker)
		{
			write("checking... ");
			checkIntegrity();
			writeln("done.");
		}
	}

	void onNameList(in char[] channelName, in char[][] nickNames)
	{
		debug(IrcTracker)
		{
			writefln("names %s: %(%s%|, %)", channelName, nickNames);
			checkIntegrity();
		}

		auto channel = _channels[channelName];

		foreach(nickName; nickNames)
		{
			if(auto pUser = nickName in _users)
			{
				auto user = *pUser;
				user.channels ~= channel.name;
				channel._users[cast(immutable)nickName] = user;
			}
			else
			{
				auto immNick = nickName.idup;

				auto user = new TrackedUser(immNick);
				user.channels = [channel.name];

				channel._users[immNick] = user;
				_users[immNick] = user;
			}
		}

		debug(IrcTracker)
		{
			import std.algorithm : map;
			writeln(channel._users.values.map!(user => *user));
			write("checking... ");
			checkIntegrity();
			writeln("done.");
		}
	}

	void onJoin(IrcUser user, in char[] channelName)
	{
		debug(IrcTracker)
		{
			writefln("%s joined %s", user.nickName, channelName);
			checkIntegrity();
		}

		auto channel = _channels[channelName];

		if(auto pUser = user.nickName in _users)
		{
			auto storedUser = *pUser;
			if(!storedUser.userName)
				storedUser.userName = user.userName.idup;
			if(!storedUser.hostName)
				storedUser.hostName = user.hostName.idup;

			storedUser.channels ~= channel.name;
			channel._users[user.nickName] = storedUser;
		}
		else
		{
			auto immNick = user.nickName.idup;

			auto newUser = new TrackedUser(immNick);
			newUser.userName = user.userName.idup;
			newUser.hostName = user.hostName.idup;
			newUser.channels = [channel.name];

			_users[immNick] = newUser;
			channel._users[immNick] = newUser;
		}

		debug(IrcTracker)
		{
			write("checking... ");
			checkIntegrity();
			writeln("done.");
		}
	}

	// Utility function
	void onMeLeave(in char[] channelName)
	{
		import std.algorithm : countUntil, remove, SwapStrategy;

		debug(IrcTracker)
		{
			writeln("onmeleave: ", channelName);
			checkIntegrity();
		}

		auto channel = _channels[channelName];

		foreach(ref user; channel._users)
		{
			auto channelIndex = user.channels.countUntil(channelName);
			assert(channelIndex != -1);
			user.channels = user.channels.remove!(SwapStrategy.unstable)(channelIndex);
			if(user.channels.length == 0 && user.nickName != client.nickName)
				_users.remove(cast(immutable)user.nickName);
		}

		_channels.remove(channel.name);

		debug(IrcTracker)
		{
			write("checking... ");
			checkIntegrity();
			writeln("done.");
		}
	}

	// Utility function
	void onLeave(in char[] channelName, in char[] nick)
	{
		import std.algorithm : countUntil, remove, SwapStrategy;

		debug(IrcTracker)
		{
			writefln("%s left %s", nick, channelName);
			checkIntegrity();
		}

		_channels[channelName]._users.remove(cast(immutable)nick);

		auto pUser = nick in _users;
		auto user = *pUser;
		auto channelIndex = user.channels.countUntil(channelName);
		assert(channelIndex != -1);
		user.channels = user.channels.remove!(SwapStrategy.unstable)(channelIndex);
		if(user.channels.length == 0)
			_users.remove(cast(immutable)nick);

		debug(IrcTracker)
		{
			write("checking... ");
			checkIntegrity();
			writeln("done.");
		}
	}

	void onPart(IrcUser user, in char[] channelName)
	{
		if(user.nickName == client.nickName)
			onMeLeave(channelName);
		else
			onLeave(channelName, user.nickName);
	}

	void onKick(IrcUser kicker, in char[] channelName, in char[] nick, in char[] comment)
	{
		debug(IrcTracker) writefln(`%s kicked %s: %s`, kicker.nickName, nick, comment);
		if(nick == client.nickName)
			onMeLeave(channelName);
		else
			onLeave(channelName, nick);
	}

	void onQuit(IrcUser user, in char[] comment)
	{
		debug(IrcTracker)
		{
			writefln("%s quit", user.nickName);
			checkIntegrity();
		}

		foreach(channelName; _users[user.nickName].channels)
		{
			debug(IrcTracker) writefln("%s left %s by quitting", user.nickName, channelName);
			_channels[channelName]._users.remove(cast(immutable)user.nickName);
		}

		_users.remove(cast(immutable)user.nickName);

		debug(IrcTracker)
		{
			write("checking... ");
			checkIntegrity();
			writeln("done.");
		}
	}

	void onNickChange(IrcUser user, in char[] newNick)
	{
		debug(IrcTracker)
		{
			writefln("%s changed nick to %s", user.nickName, newNick);
			checkIntegrity();
		}

		_users[user.nickName].nickName = newNick.idup;

		debug(IrcTracker)
		{
			write("checking... ");
			checkIntegrity();
			writeln("done.");
		}
	}

	this(IrcClient client)
	{
		this._client = client;
		start();
	}

	alias eventHandlers = TypeTuple!(
		onSuccessfulJoin, onNameList, onJoin, onPart, onKick, onQuit, onNickChange
	);

	public:
	~this()
	{
		stop();
	}

	/**
	 * Initiate or restart tracking, or do nothing if the tracker is already tracking.
	 */
	void start()
	{
		if(_isTracking)
			return;

		foreach(handler; eventHandlers)
			mixin("client." ~ __traits(identifier, handler)) ~= &handler;

		auto thisNick = _client.nickName;
		thisUser = new TrackedUser(thisNick);
		thisUser.userName = _client.userName;
		thisUser.realName = _client.realName;
		_users[thisNick] = thisUser;

		_isTracking = true;
	}

	/**
	 * Stop tracking, or do nothing if the tracker is not currently tracking.
	 */
	void stop()
	{
		if(!_isTracking)
			return;

		_users = null;
		thisUser = null;
		_channels = null;
		_isTracking = false;

		foreach(handler; eventHandlers)
			mixin("client." ~ __traits(identifier, handler)).unsubscribeHandler(&handler);
	}

	/// Boolean whether or not the tracker is currently tracking.
	bool isTracking() const @property @safe pure nothrow
	{
		return _isTracking;
	}

	/// $(DPREF _client, IrcClient) that this tracker is tracking for.
	inout(IrcClient) client() inout @property @safe pure nothrow
	{
		return _client;
	}

	/**
	 * $(D InputRange) (with $(D length)) of all _channels the associated client is currently
	 * a member of.
	 * Throws:
	 *    $(MREF IrcTrackingException) if tracking is currently disabled
	 */
	auto channels() @property
	{
		import std.range : takeExactly;
		enforceEx!IrcTrackingException(_isTracking, "the tracker is currently disabled");
		return _channels.byValue.takeExactly(_channels.length);
	}

	unittest
	{
		import std.range;
		static assert(isInputRange!(typeof(IrcTracker.init.channels)));
		static assert(is(ElementType!(typeof(IrcTracker.init.channels)) == TrackedChannel));
		static assert(hasLength!(typeof(IrcTracker.init.channels)));
	}

	/**
	 * $(D InputRange) (with $(D length)) of all _users currently seen by the associated client.
	 *
	 * The range includes the user for the associated client. Users that are not a member of any
	 * of the channels the associated client is a member of, but have sent a private message to
	 * the associated client, are $(I not) included.
	 * Throws:
	 *    $(MREF IrcTrackingException) if tracking is currently disabled
	 */
	auto users() @property
	{
		import std.algorithm : map;
		import std.range : takeExactly;
		enforceEx!IrcTrackingException(_isTracking, "the tracker is currently disabled");
		return _users.byValue.takeExactly(_users.length);
	}

	unittest
	{
		import std.range;
		static assert(isInputRange!(typeof(IrcTracker.init.users)));
		static assert(is(ElementType!(typeof(IrcTracker.init.users)) == TrackedUser*));
		static assert(hasLength!(typeof(IrcTracker.init.users)));
	}

	/**
	 * Lookup a channel on this tracker by name.
	 * The channel name must include the channel name prefix.
	 *
	 * If the associated client is not a member of the given channel,
	 * the returned $(MREF TrackedChannel) is in the invalid state.
	 * Params:
	 *    channelName = name of channel to lookup
	 * See_Also:
	 *    $(MREF IrcChannel)
	 */
	TrackedChannel* findChannel(in char[] channelName)
	{
		return channelName in _channels;
	}

	/**
	 * Lookup a user on this tracker by nick name.
	 *
	 * If the target user does not share membership in any channel
	 * with the associated client for this tracker, the returned
	 * $(MREF TrackedUser) is in the invalid state.
	 * Params:
	 *    channelName = name of channel to lookup
	 * See_Also:
	 *    $(MREF IrcChannel)
	 */
	TrackedUser* findUser(in char[] nickName)
	{
		if(auto user = nickName in _users)
			return *user;
		else
			return null;
	}
}

/**
 * Represents an IRC channel and its member users for use by $(MREF IrcTracker).
 *
 * Has an invalid state that can be checked by coercion to $(D bool).
 * $(D TrackedChannel.init) is also in the invalid state.
 *
 * The list of members includes the user associated with the tracking object.
 * If the $(D IrcTracker) used to access an instance of this type
 * is since stopped, the channel presents the list of members as it were
 * at the time of the tracker being stopped.
 */
struct TrackedChannel
{
	private:
	immutable string _name;
	TrackedUser*[string] _users;

	this(string name)
	{
		_name = name;
	}

	public:
	///
	@disable this();

	/// Name of the channel, including the channel prefix.
	string name() @property
	{
		return _name;
	}

	/// $(D InputRange) of all member _users of this channel,
	/// where each user is given as a $(D (MREF TrackedUser)*).
	auto users() @property
	{
		import std.range : takeExactly;
		return _users.byValue.takeExactly(_users.length);
	}

	/**
	 * Lookup a member of this channel by nick name.
	 * $(D null) is returned if the given nick is not a member
	 * of this channel.
	 * Params:
	 *   nick = nick name of member to lookup
	 */
	TrackedUser* opBinary(string op : "in")(in char[] nick)
	{
		enforceEx!IrcTrackingException(cast(bool)this, "the TrackedChannel is invalid");
		if(auto pUser = nick in _users)
			return *pUser;
		else
			return null;
	}
}

/**
 * Represents an IRC user for use by $(MREF IrcTracker).
 *
 * Has an invalid state that can be checked by coercion to $(D bool).
 * $(D TrackedUser.init) is also in the invalid state.
 */
struct TrackedUser
{
	private:
	this(string nickName)
	{
		this.nickName = nickName;
	}

	public:
	///
	@disable this();

	/**
	 * Nick name, user name and host name of the _user.
	 *
	 * Only the nick name is guaranteed to be non-null.
	 * See_Also:
	 *   $(DPREF protocol, IrcUser)
	 */
	IrcUser user;

	/// Ditto
	alias user this;

    /// Real name of the user. Is $(D null) unless a whois-query
    /// has been successfully issued for the user.
	string realName;

	/**
	 * Channels in which both the current user and the tracked
	 * user share membership.
	 *
	 * See_Also:
	 * $(DPREF client, IrcClient.queryWhois) to query channels
	 * a user is in, regardless of shared membership with the current user.
	 */
	string[] channels;

	void toString(scope void delegate(const(char)[]) sink) const
	{
		import std.format;
		user.toString(sink);
		formattedWrite(sink, "(%(%s%|,%))", channels);
	}
}
