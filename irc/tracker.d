module irc.tracker;

import irc.client;
import irc.util : ExceptionConstructor;

import std.exception : enforceEx;
import std.typetuple : TypeTuple;

/// Can be thrown by $(MREF IrcTracker.channels).
class IrcTrackingException : Exception
{
	mixin ExceptionConstructor!();
}

/**
 * Create a new channel and user tracking object for the given
 * $(DPREF client, IrcClient). Tracking for the new object
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
	IrcChannel[string] _channels;
	bool _isTracking = false;

	debug(IrcTracker) import std.stdio;

	final:
	void onSuccessfulJoin(in char[] channelName)
	{
		debug(IrcTracker) writeln("onmejoin: ", channelName);
		auto channel = IrcChannel(channelName.idup);

		// Give the channel identity by initializing the AA
		channel._users = [_client.nick: IrcUser(_client.nick, _client.userName, _client.realName)];

		_channels[channel.name] = channel;
	}

	void onNameList(in char[] channelName, in char[][] nickNames)
	{
		debug(IrcTracker) writefln("names %s: %(%s%|, %)", channelName, nickNames);
		if(auto channel = channelName in _channels)
		{
			foreach(nickName; nickNames)
				channel._users[nickName] = IrcUser(nickName.idup);
			debug(IrcTracker) writeln(channel._users.values);
		}
	}

	void onJoin(IrcUser user, in char[] channelName)
	{
		debug(IrcTracker) writefln("%s joined %s", user.nick, channelName);

		if(auto channel = channelName in _channels)
		{
			auto immNick = user.nick.idup;
			user.nick = immNick;
			channel._users[immNick] = user;
		}
	}

	void onMePart(in char[] channelName)
	{
		_channels.remove(channelName.idup);
	}

	// Utility function
	void onLeave(in char[] channelName, in char[] nick)
	{ 
		debug(IrcTracker) writefln("%s left %s", nick, channelName);
		_channels[channelName]._users.remove(nick.idup /* ew */);
	}

	void onPart(IrcUser user, in char[] channelName)
	{
		onLeave(channelName, user.nick);
	}

	void onKick(IrcUser kicker, in char[] channelName, in char[] nick, in char[] comment)
	{
		onLeave(channelName, nick);
	}

	void onQuit(IrcUser user, in char[] comment)
	{
		debug(IrcTracker) writefln("%s quit", user.nick);
		foreach(ref channel; _channels)
		{
			if(user.nick in channel._users)
			{
				debug(IrcTracker) writefln("%s left %s by quitting", user.nick, channel.name);
				channel._users.remove(user.nick.idup /* ew */);
			}
		}
	}

	void onNickChange(IrcUser user, in char[] newNick)
	{
		if(user.nick != _client.nick)
		{
			string immNewNick;

			foreach(ref channel; _channels)
			{
				if(auto userInSet = user.nick in channel._users)
				{
					if(!immNewNick)
						immNewNick = newNick.idup;

					userInSet.nick = immNewNick;
				}
			}
		}
	}

	this(IrcClient client)
	{
		this._client = client;
		start();
	}

	alias handlers = TypeTuple!(
		onSuccessfulJoin, onNameList, onJoin, onMePart, onKick, onQuit, onNickChange
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

		scope(success) _isTracking = true;

		foreach(handler; handlers)
			mixin("client." ~ __traits(identifier, handler)) ~= &handler;
	}

	/**
	 * Stop tracking, or do nothing if the tracker is not currently tracking.
	 */
	void stop()
	{
		if(!_isTracking)
			return;

		_channels = null;
		_isTracking = false;

		foreach(handler; handlers)
			mixin("client." ~ __traits(identifier, handler)).unsubscribeHandler(&handler);
	}

	/// Boolean whether or not the tracker is currently tracking.
	bool isTracking() const @property @safe pure nothrow
	{
		return _isTracking;
	}

	/// $(DPREF client, IrcClient) that this tracker is tracking for.
	inout(IrcClient) client() inout @property @safe pure nothrow
	{
		return _client;
	}

	/**
	 * $(D InputRange) of all _channels the associated client is currently
	 * a member of.
	 * Throws:
	 *    $(MREF IrcTrackingException) if tracking is currently disabled
	 */
	auto channels() @property
	{
		enforceEx!IrcTrackingException(_isTracking, "the tracker is currently disabled");
		return _channels.values; // TODO: use .byValue once available (Using 2.064 yet?)
	}

	/**
	* Lookup a channel on this tracker by name. 
	* The channel name must include the channel name prefix.
	*
	* Params:
	*    channelName = name of channel to lookup
	* Throws:
	*    $(D RangeError) if the associated client is not
	*    a member of the given channel
	* See_Also:
	*    $(MREF IrcChannel)
	*/
	IrcChannel opIndex(in char[] channelName)
	{
		return _channels[channelName];
	}

	/**
	 * Same as $(MREF IrcTracker.opIndex), except $(D null) is returned
	 * instead of throwing if the associated client is not
	 * a member of the given channel.
	 */
	IrcChannel* opBinary(string op : "in")(in char[] channelName)
	{
		return channelName in _channels;
	}
}

/**
 * Represents an IRC channel and its member users for use by $(MREF IrcTracker).
 *
 * The list of members includes the user associated with the tracking object.
 * If the $(D IrcTracker) used to access an instance of this type
 * is since stopped, the channel presents the list of members as it were
 * at the time of the tracker being stopped.
 */
struct IrcChannel
{
	string _name;
	private IrcUser[string] _users;

	/// Name of the channel, including the channel prefix.
	string name() @property
	{
		return _name;
	}

	/// $(D InputRange) of all member users of this channel,
	/// where each user is given as an (DPREF protocol, IrcUser).
	auto users() @property
	{
		return _users.values; // TODO: use .byValue once available (Using 2.064 yet?)
	}

	/**
	 * Lookup a member of this channel by nickname.
	 * $(D null) is returned if the given nick is not a member
	 * of this channel.
	 * Params:
	 *   nick = nickname of member to lookup
	 */
	IrcUser* opBinary(string op : "in")(in char[] nick)
	{
		return nick in _users;
	}
}
