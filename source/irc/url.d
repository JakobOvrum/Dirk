module irc.url;

import std.array;
import std.conv : to, ConvException;
import std.regex;
import std.string : icmp, indexOf;

import irc.protocol : channelPrefixes;

/// Result of the $(MREF parse) and $(MREF tryParse) functions,
/// containing the parsed connection information.
struct ConnectionInfo
{
	/// Server address.
	string address;

	/// Explicitly specified server port, or $(D 0) when unspecified.
	ushort explicitPort;

	/**
	 * Server port.
	 *
	 * Evaluates to $(MREF ConnectionInfo.explicitPort) when an explicit
	 * port was specified, and $(MREF ConnectionInfo.defaultPort) otherwise.
	 */
	ushort port() @property @safe pure nothrow
	{
		return explicitPort == 0? defaultPort : explicitPort;
	}

	/// Security protocol. Is $(D true) for TLS/SSL,
	/// and $(D false) for no security.
	bool secure;

	/// Channels to join immediately after a successful connect. Can be empty.
	string[] channels;

	/// Key/passphrase to use when joining channels.
	/// Is $(D null) when unspecified.
	string channelKey;

	/// Default port for the specified security protocol.
	/// $(D 6697) for TLS/SSL, and $(D 6667) otherwise.
	ushort defaultPort() @property @safe pure nothrow
	{
		return secure? 6697 : 6667;
	}
}

///
class IrcUrlException : Exception
{
	/// Same as $(MREF ParseError.location).
	size_t location;

	this(string msg, size_t location, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow
	{
		this.location = location;
		super(msg, file, line, next);
	}
}

/**
 * Parse IRC URLs (also known as "chat links").
 *
 * Channels without a valid prefix are automatically
 * prefixed with '#'.
 */
// TODO: describe supported URL format in detail
ConnectionInfo parse(string url) @safe
{
	ConnectionInfo info;

	if(auto error = url.tryParse(info))
		throw new IrcUrlException(error.message, error.location);

	return info;
}

///
unittest
{
	ConnectionInfo info;

	info = parse("ircs://irc.example.com:6697/foo,bar");

	assert(info.address == "irc.example.com");
	assert(info.explicitPort == 6697);
	assert(info.port == 6697);
	assert(info.secure);
	assert(info.channels == ["#foo", "#bar"]);

	info = parse("irc://irc.example.org/foo?pass");

	assert(info.address == "irc.example.org");
	assert(info.explicitPort == 0);
	assert(info.port == 6667); // No explicit port, so it falls back to the default IRC port
	assert(!info.secure);
	assert(info.channels == ["#foo"]);
	assert(info.channelKey == "pass");
}

///
struct ParseError
{
	/// Error message.
	string message;

	/// Location in input (zero-based column) the error occured.
	/// Ranges from $(D 0 .. $ - 1), where the $(D $) symbol is the length of the input.
	size_t location = 0;

	private bool wasError = true;

	/// Boolean whether or not an error occured. If an error did not occur,
	/// $(D message) and $(D location) will not have meaningful values.
	bool opCast(T)() @safe pure if(is(T == bool))
	{
		return wasError;
	}

	///
	@safe pure unittest
	{
		auto error = ParseError("error occured!", 0);
		assert(error); // conversion to $(D bool)
	}
}

/**
 * Same as $(MREF parse), but returning an error message instead of throwing.
 * Useful for high-volume parsing.
 */
ParseError tryParse(string url, out ConnectionInfo info) @trusted /+ @safe nothrow +/
{
	static urlPattern =
		ctRegex!(
			`^([^:]+)://` ~ // Protocol
			`([^:/]+)(:\+?[^/]+)?` ~ // Address and optional port
			`/?([^\?]+)?` ~ // Optional channel list
			`\??(.*)$`, // Optional channel key
			"ix"
		);

	typeof(url.match(urlPattern)) m;

	try m = url.match(urlPattern);
	catch(Exception ex)
	{
		return ParseError(ex.msg);
	}

	if(!m)
		return ParseError("input is not a URL");

	auto captures = m.captures;
	captures.popFront(); // skip whole match

	// Handle protocol
	auto protocol = captures.front;
	captures.popFront();

	if(protocol.icmp("irc") != 0 && protocol.icmp("ircs") != 0)
		return ParseError(`connection protocol must be "irc" or "ircs", not ` ~ protocol);

	info.secure = protocol.icmp("ircs") == 0;

	// Handle address
	info.address = captures.front;
	captures.popFront();

	// Handle port
	auto strPort = captures.front;

	auto pre = captures.pre;
	auto post = captures.post;
	auto hit = captures.hit;

	if(strPort.length > 1)
	{
		strPort.popFront; // Skip colon

		if(strPort.front == '+')
		{
			info.secure = true;
			strPort.popFront;
		}

		try info.explicitPort = to!ushort(strPort);
		catch(ConvException e)
			return ParseError("Error parsing port: " ~ e.msg, url.indexOf(strPort)); // TODO: shouldn't have to search
	}

	captures.popFront();

	// Handle channels
	auto tail = captures.front;

	if(!tail.empty)
	{
		info.channels = tail.split(",");

		foreach(ref channel; info.channels)
		{
			switch(channel[0])
			{
				foreach(prefix; channelPrefixes)
					case prefix:
						break;

				default:
					channel = '#' ~ channel;
			}
		}
	}

	captures.popFront();

	// Handle channel key
	auto key = captures.front;

	if(!key.empty)
		info.channelKey = key;

	return ParseError(null, 0, false);
}

/// Parse list of URLs and write any errors to $(D stderr)
/// with column information.
unittest
{
	import std.stdio : stderr;

	auto urls = ["irc://example.com", "ircs://example.org/foo?pass"];

	foreach(url; urls)
	{
		ConnectionInfo info;

		if(auto error = url.tryParse(info))
		{
			stderr.writefln("Error parsing URL:\n%s\n%*s\n%s", url, error.location + 1, "^", error.message);
			continue;
		}

		// Use `info`
	}
}

unittest
{
	import std.stdio : writeln;

	static struct Test
	{
		string url;
		ConnectionInfo expectedResult;
	}

	auto tests = [
		Test("irc://example.com",
			 ConnectionInfo("example.com", 0, false)
		),
		Test("ircs://example.com",
			 ConnectionInfo("example.com", 0, true)
		),
		Test("irc://example.org:6667",
			 ConnectionInfo("example.org", 6667, false)
		),
		Test("irc://example.org:+6697",
			 ConnectionInfo("example.org", 6697, true)
		),
		Test("iRc://example.info/example",
			 ConnectionInfo("example.info", 0, false, ["#example"])
		),
		Test("IRCS://example.info/example?passphrase",
			 ConnectionInfo("example.info", 0, true, ["#example"], "passphrase")
		),
		Test("irc://test/example,test",
			 ConnectionInfo("test", 0, false, ["#example", "#test"])
		),
		Test("ircs://test/example,test,foo?pass",
			 ConnectionInfo("test", 0, true, ["#example", "#test", "#foo"], "pass")
		),
		Test("ircs://example.com:+6697/foo,bar,baz?pass",
			 ConnectionInfo("example.com", 6697, true, ["#foo", "#bar", "#baz"], "pass")
		)
	];

	foreach(i, ref test; tests)
	{
		immutable msg = "test #" ~ to!string(i + 1);

		ConnectionInfo result;
		auto error = tryParse(test.url, result);

		scope(failure) debug writeln(error);

		assert(!error);

		scope(failure) debug writeln(result);

		assert(result.address == test.expectedResult.address, msg);
		assert(result.port == test.expectedResult.port, msg);
		assert(result.secure == test.expectedResult.secure, msg);
		assert(result.channels == test.expectedResult.channels, msg);
		assert(result.channelKey == test.expectedResult.channelKey, msg);
	}

	// TODO: test error paths
}
