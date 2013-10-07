module irc.tracker;

import irc.client;

import std.typetuple : TypeTuple;

IrcTracker track(IrcClient client)
{
	return new IrcTracker(client);
}

// TODO: mode tracking
class IrcTracker
{
	private:
	IrcClient _client;
	IrcChannel[string] _channels;
	bool _isTracking = false;

	debug import std.stdio;

	final:
	void onSuccessfulJoin(in char[] channelName)
	{
		debug writeln("onmejoin: ", channelName);
		auto channel = IrcChannel(channelName.idup);
		_channels[channel.name] = channel;
	}

	void onNameList(in char[] channelName, in char[][] nickNames)
	{
		debug writefln("names %s: %(%s%|, %)", channelName, nickNames);
		if(auto channel = channelName in _channels)
		{
			foreach(nickName; nickNames)
				channel._users[nickName] = IrcUser(nickName.idup);
			debug writeln(channel._users.values);
		}
	}

	void onJoin(IrcUser user, in char[] channelName)
	{
		debug writefln("%s joined %s", user.nick, channelName);

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
		debug writefln("%s left %s", nick, channelName);
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
		debug writefln("%s quit", user.nick);
		foreach(ref channel; _channels)
		{
			if(user.nick in channel._users)
			{
				debug writefln("%s left %s by quitting", user.nick, channel.name);
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
	void start()
	{
		if(_isTracking)
			return;

		scope(success) _isTracking = true;

		foreach(handler; handlers)
			mixin("client." ~ __traits(identifier, handler)) ~= &handler;
	}

	void stop()
	{
		if(!_isTracking)
			return;

		_channels = null;
		_isTracking = false;

		foreach(handler; handlers)
			mixin("client." ~ __traits(identifier, handler)).unsubscribeHandler(&handler);
	}

	bool isTracking() const @property @safe pure nothrow
	{
		return _isTracking;
	}

	inout(IrcClient) client() inout @property @safe pure nothrow
	{
		return _client;
	}

	auto channels() @property
	{
		return _channels.values; // TODO: use .byValue once available (Using 2.064 yet?)
	}

	IrcChannel* opBinary(string op : "in")(in char[] channel)
	{
		return channel in _channels;
	}

	IrcChannel opIndex(in char[] channelName)
	{
		return _channels[channelName];
	}
}

struct IrcChannel
{
	string _name;
	private IrcUser[string] _users;

	string name() @property
	{
		return _name;
	}

	auto users() @property
	{
		return _users.values; // TODO: use .byValue once available (Using 2.064 yet?)
	}

	IrcUser* opBinary(string op : "in")(in char[] nick)
	{
		return nick in _users;
	}
}
