// TODO: more accurate/atomic tracking starting procedure
module irc.tracker;

import irc.client;
import irc.util : ExceptionConstructor;

import std.exception : enforceEx;
import std.traits : Unqual;
import std.typetuple : TypeTuple;

///
class IrcTrackingException : Exception
{
	mixin ExceptionConstructor!();
}

// TODO: Add example
/**
 * Create a new channel and user tracking object for the given
 * $(DPREF _client, IrcClient). Tracking for the new object
 * is initially disabled; use $(MREF IrcTracker.start) to commence tracking.
 *
 * Params:
 *   Payload = type of extra storage per $(MREF TrackedUser) object
 * See_Also:
 *    $(MREF IrcTracker), $(MREF TrackedUser.payload)
 */
CustomIrcTracker!Payload track(Payload = void)(IrcClient client)
{
	return new typeof(return)(client);
}

/**
 * Keeps track of all channels and channel members
 * visible to the associated $(DPREF client, IrcClient) connection.
 *
 * Params:
 *   Payload = type of extra storage per $(MREF TrackedUser) object
 * See_Also:
 *   $(MREF CustomTrackedUser.payload)
 */
class CustomIrcTracker(Payload = void)
{
	// TODO: mode tracking
	private:
	IrcClient _client;
	CustomTrackedChannel!Payload[string] _channels;
	CustomTrackedUser!Payload*[string] _users;
	CustomTrackedUser!Payload* thisUser;

	enum State { disabled, starting, enabled }
	auto _isTracking = State.disabled;

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

		auto channel = CustomTrackedChannel!Payload(channelName.idup);
		channel._users = [_client.nickName: thisUser];
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

				auto user = new CustomTrackedUser!Payload(immNick);
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

			auto newUser = new CustomTrackedUser!Payload(immNick);
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

	alias eventHandlers = TypeTuple!(
		onSuccessfulJoin, onNameList, onJoin, onPart, onKick, onQuit, onNickChange
	);

	// Start tracking functions
	void onMyChannelsReply(in char[] nick, in char[][] channels)
	{
		if(nick != client.nickName)
			return;

		_client.onWhoisChannelsReply.unsubscribeHandler(&onMyChannelsReply);
		_client.onWhoisEnd.unsubscribeHandler(&onWhoisEnd);

		if(_isTracking != State.starting)
			return;

		startNow();

		foreach(channel; channels)
			onSuccessfulJoin(channel);

		_client.queryNames(channels);
	}

	void onWhoisEnd(in char[] nick)
	{
		if(nick != client.nickName)
			return;

		// Weren't in any channels.

		_client.onWhoisChannelsReply.unsubscribeHandler(&onMyChannelsReply);
		_client.onWhoisEnd.unsubscribeHandler(&onWhoisEnd);

		if(_isTracking != State.starting)
			return;

		startNow();
	}

	private void startNow()
	{
		assert(_isTracking != State.enabled);

		foreach(handler; eventHandlers)
			mixin("client." ~ __traits(identifier, handler)) ~= &handler;

		auto thisNick = _client.nickName;
		thisUser = new CustomTrackedUser!Payload(thisNick);
		thisUser.userName = _client.userName;
		thisUser.realName = _client.realName;
		_users[thisNick] = thisUser;

		_isTracking = State.enabled;
	}

	public:
	this(IrcClient client)
	{
		this._client = client;
	}

	~this()
	{
		stop();
	}

	/**
	 * Initiate or restart tracking, or do nothing if the tracker is already tracking.
	 *
	 * If the associated client is unconnected, tracking starts immediately.
	 * If it is connected, information about the client's current channels will be queried,
	 * and tracking starts as soon as the information has been received.
	 */
	void start()
	{
		if(_isTracking != State.disabled)
			return;

		if(_client.connected)
		{
			_client.onWhoisChannelsReply ~= &onMyChannelsReply;
			_client.onWhoisEnd ~= &onWhoisEnd;
			_client.queryWhois(_client.nickName);
			_isTracking = State.starting;
		}
		else
			startNow();
	}

	/**
	 * Stop tracking, or do nothing if the tracker is not currently tracking.
	 */
	void stop()
	{
		final switch(_isTracking)
		{
			case State.enabled:
				_users = null;
				thisUser = null;
				_channels = null;
				foreach(handler; eventHandlers)
					mixin("client." ~ __traits(identifier, handler)).unsubscribeHandler(&handler);
				break;
			case State.starting:
				_client.onWhoisChannelsReply.unsubscribeHandler(&onMyChannelsReply);
				_client.onWhoisEnd.unsubscribeHandler(&onWhoisEnd);
				break;
			case State.disabled:
				return;
		}

		_isTracking = State.disabled;
	}

	/// Boolean whether or not the tracker is currently tracking.
	bool isTracking() const @property @safe pure nothrow
	{
		return _isTracking == State.enabled;
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
	 *    $(MREF IrcTrackingException) if the tracker is disabled or not yet ready
	 */
	auto channels() @property
	{
		import std.range : takeExactly;
		enforceEx!IrcTrackingException(_isTracking, "not currently tracking");
		return _channels.byValue.takeExactly(_channels.length);
	}

	unittest
	{
		import std.range;
		static assert(isInputRange!(typeof(CustomIrcTracker.init.channels)));
		static assert(is(ElementType!(typeof(CustomIrcTracker.init.channels)) : CustomTrackedChannel!Payload));
		static assert(hasLength!(typeof(CustomIrcTracker.init.channels)));
	}

	/**
	 * $(D InputRange) (with $(D length)) of all _users currently seen by the associated client.
	 *
	 * The range includes the user for the associated client. Users that are not a member of any
	 * of the channels the associated client is a member of, but have sent a private message to
	 * the associated client, are $(I not) included.
	 * Throws:
	 *    $(MREF IrcTrackingException) if the tracker is disabled or not yet ready
	 */
	auto users() @property
	{
		import std.algorithm : map;
		import std.range : takeExactly;
		enforceEx!IrcTrackingException(_isTracking, "not currently tracking");
		return _users.byValue.takeExactly(_users.length);
	}

	unittest
	{
		import std.range;
		static assert(isInputRange!(typeof(CustomIrcTracker.init.users)));
		static assert(is(ElementType!(typeof(CustomIrcTracker.init.users)) == CustomTrackedUser!Payload*));
		static assert(hasLength!(typeof(CustomIrcTracker.init.users)));
	}

	/**
	 * Lookup a channel on this tracker by name.
	 *
	 * The channel name must include the channel name prefix. Returns $(D null)
	 * if the associated client is not currently a member of the given channel.
	 * Params:
	 *    channelName = name of channel to lookup
	 * Throws:
	 *    $(MREF IrcTrackingException) if the tracker is disabled or not yet ready
	 * See_Also:
	 *    $(MREF TrackedChannel)
	 */
	CustomTrackedChannel!Payload* findChannel(in char[] channelName)
	{
		enforceEx!IrcTrackingException(_isTracking, "not currently tracking");
		return channelName in _channels;
	}

	/**
	 * Lookup a user on this tracker by nick name.
	 *
	 * Users are searched among the members of all channels the associated
	 * client is currently a member of. The set includes the user for the
	 * associated client.
	 * Params:
	 *    nickName = nick name of user to lookup
	 * Throws:
	 *    $(MREF IrcTrackingException) if the tracker is disabled or not yet ready
	 * See_Also:
	 *    $(MREF TrackedUser)
	 */
	CustomTrackedUser!Payload* findUser(in char[] nickName)
	{
		enforceEx!IrcTrackingException(_isTracking, "not currently tracking");
		if(auto user = nickName in _users)
			return *user;
		else
			return null;
	}
}

/// Ditto
alias IrcTracker = CustomIrcTracker!void;

/**
 * Represents an IRC channel and its member users for use by $(MREF IrcTracker).
 *
 * The list of members includes the user associated with the tracking object.
 * If the $(D IrcTracker) used to access an instance of this type
 * was since stopped, the channel presents the list of members as it were
 * at the time of the tracker being stopped.
 *
 * Params:
 *   Payload = type of extra storage per $(MREF TrackedUser) object
 * See_Also:
 *   $(MREF CustomTrackedUser.payload)
 */
struct CustomTrackedChannel(Payload = void)
{
	private:
	immutable string _name;
	CustomTrackedUser!Payload*[string] _users;

	this(string name, CustomTrackedUser!Payload*[string] users = null)
	{
		_name = name;
		_users = users;
	}

	public:
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
	CustomTrackedUser!Payload* opBinary(string op : "in")(in char[] nick)
	{
		enforceEx!IrcTrackingException(cast(bool)this, "the TrackedChannel is invalid");
		if(auto pUser = nick in _users)
			return *pUser;
		else
			return null;
	}

	static if(!is(Payload == void))
	{
		TrackedChannel erasePayload() @property
		{
			return TrackedChannel(_name, cast(TrackedUser*[string])_users);
		}

		alias erasePayload this;
	}
}

/// Ditto
alias TrackedChannel = CustomTrackedChannel!void;

/**
 * Represents an IRC user for use by $(MREF IrcTracker).
 */
struct TrackedUser
{
	private:
	this(string nickName)
	{
		this.nickName = nickName;
	}

	public:
	@disable this();

	/**
	 * Nick name, user name and host name of the _user.
	 *
	 * $(D TrackedUser) is a super-type of $(DPREF protocol, IrcUser).
	 *
	 * Only the nick name is guaranteed to be non-null.
	 * See_Also:
	 *   $(DPREF protocol, IrcUser)
	 */
	IrcUser user;

	/// Ditto
	alias user this;

    /**
     * Real name of the user. Is $(D null) unless a whois-query
     * has been successfully issued for the user.
     *
     * See_Also:
     *   $(DPREF client, IrcClient.queryWhois)
     */
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

		if(realName)
		{
			sink("$");
			sink(realName);
		}

		formattedWrite(sink, "(%(%s%|,%))", channels);
	}

	unittest
	{
		import std.string : format;
		auto user = TrackedUser("nick");
		user.userName = "user";
		user.realName = "Foo Bar";
		user.channels = ["#a", "#b"];
		assert(format("%s", user) == `nick!user$Foo Bar("#a","#b")`);
	}
}

/**
 * Represents an IRC user for use by $(MREF CustomIrcTracker).
 * Params:
 *   Payload = type of extra data per user.
 */
align(1) struct CustomTrackedUser(Payload)
{
	/// $(D CustomTrackedUser) is a super-type of $(MREF TrackedUser).
	TrackedUser user;

	/// Ditto
	alias user this;

	/**
	 * Extra data attached to this user for per-application data.
     */
	Payload payload;

	///
	this(string nickName)
	{
		user = TrackedUser(nickName);
	}
}

///
alias CustomTrackedUser(Payload : void) = TrackedUser;
