module irc.testing;

version(unittest):

import std.socket;

import irc.client;
import irc.protocol;

immutable testRealName = "Test Name";
auto testUser = IrcUser("TestNick", "user", "test.org");

class TestConnection
{
	private:
	Socket clientSocket, server;
	char[512] _lineBuffer;

	public:
	IrcClient client;

	this()
	{
        auto listener = new TcpSocket();
		scope(exit) listener.close();

		auto serverAddress = parseAddress("127.0.0.1", InternetAddress.PORT_ANY);
        listener.bind(serverAddress);
        listener.listen(1);

		this.clientSocket = new TcpSocket();
		this.client = new IrcClient(clientSocket);
		client.nickName = testUser.nickName;
		client.userName = testUser.userName.idup;
		client.realName = testRealName;

		this.client.connect(listener.localAddress);

		server = listener.accept();
	}

	void injectfln(FmtArgs...)(const(char)[] fmt, FmtArgs fmtArgs)
	{
		import std.string : sformat;

		enum doFormat = fmtArgs.length > 0;

		static if(doFormat)
		{
			fmt = _lineBuffer[0 .. 510].sformat(fmt, fmtArgs);
			_lineBuffer[fmt.length .. fmt.length + 2] = "\r\n";
			fmt = _lineBuffer[0 .. fmt.length + 2];
		}

		server.send(fmt);

		static if(!doFormat)
			server.send("\r\n");
	}

	// TODO: Write a proper implementation
	IrcLine getLine()
	{
		char recvChar()
		{
			char c;
			auto received = server.receive((&c)[0 .. 1]);
			assert(received == 1);
			return c;
		}

		size_t lineLength = 0;

		for(;;)
		{
			auto c = recvChar();

			if(c == '\r')
				break;
			else
				_lineBuffer[lineLength++] = c;
		}

		char lf = recvChar();
		assert(lf == '\n');

		auto rawLine = _lineBuffer[0 .. lineLength];

		IrcLine line;
		rawLine.parse(line);
		return line;
	}

	IrcLine assertLine(in char[] cmd, in char[][] args...)
	{
		import std.string : format;

		auto line = getLine();

		void assertOriginator(IrcUser originator)
		{
			assert(originator.nickName == testUser.nickName, `expected nickname "%s", got "%s")`.format(testUser.nickName, originator.nickName));
			assert(originator.userName == null, `got username, expected none`);
			assert(originator.hostName == null, `got hostname, expected none`);
		}

		if(line.prefix)
		{
			import core.exception : AssertError;

			try assertOriginator(IrcUser.fromPrefix(line.prefix));
			catch(AssertError e)
				throw new AssertError("the only valid origin a client can send is the client's nickname", __FILE__, __LINE__, e);
		}

		assert(line.command == cmd, `expected command "%s", got "%s"`.format(cmd, line.command));

		foreach(i, arg; args)
		{
			if(arg.ptr)
				assert(line.arguments[i] == arg,
					`argument #%d did not match expectations; got "%s", expected "%s"`
					.format(i + 1, line.arguments[i], arg));
		}

		return line;
	}
}

unittest
{
	import std.algorithm : joiner;
	import std.range : chain, iota, only, repeat;
	import std.typetuple : TypeTuple;

	auto conn = new TestConnection();
	auto origin = "testserver";
	auto client = conn.client;

	struct TestEvent(string eventName)
	{
		import std.traits;
		alias HandlerType = typeof(mixin("IrcClient." ~ eventName)[0]);
		alias Args = ParameterTypeTuple!HandlerType;
		alias Ret = ReturnType!HandlerType;

		Ret delegate(Args) handler;
		bool prepared = false, ran = false;

		@disable this(this);

		static if(is(Ret == void))
			alias ExpectedRet = TypeTuple!();
		else
			alias ExpectedRet = Ret;

		void prepare(ExpectedRet expectedRet, Args expectedArgs)
		{
			handler = delegate Ret(Args args) {
				ran = true;
				assert(args == expectedArgs);
				static if (!is(Ret == void))
					return expectedRet;
			};

			mixin("client." ~ eventName) ~= handler;
			prepared = true;
		}

		void check()
		{
			assert(prepared);
			assert(ran);
			mixin("client." ~ eventName).unsubscribeHandler(handler);
		}
	}

	auto socketSet = new SocketSet(1);
	socketSet.add(conn.clientSocket);
	void handleClientEvents()
	{
		Socket.select(socketSet, null, null);
		assert(socketSet.isSet(conn.clientSocket));
		assert(!client.read());
	}

	conn.assertLine("NICK", testUser.nickName);
	conn.assertLine("USER", testUser.userName, null, null, testRealName);

	{
		TestEvent!"onNickInUse" onNickInUse;
		auto newNickName = testUser.nickName ~ "_";
		onNickInUse.prepare(newNickName, testUser.nickName);
		conn.injectfln(":%s 433 * %s :Nickname is already in use", origin, testUser.nickName);
		handleClientEvents();
		onNickInUse.check();
		conn.assertLine("NICK", newNickName);
		testUser.nickName = newNickName;
	}

	TestEvent!"onConnect" onConnect;
	onConnect.prepare();
	conn.injectfln(":%s 001 %s :Welcome to the test server", origin, testUser.nickName);
	handleClientEvents();
	onConnect.check();

	conn.injectfln(":%s PING :hello world", origin);
	handleClientEvents();
	conn.assertLine("PONG", "hello world");

	client.join("#test");
	conn.assertLine("JOIN", "#test");

	TestEvent!"onSuccessfulJoin" onSuccessfulJoin;
	onSuccessfulJoin.prepare("#test");
	conn.injectfln(":%s JOIN #test", testUser);
	handleClientEvents();
	onSuccessfulJoin.check();

	TestEvent!"onNameList" onNameList;
	onNameList.prepare("#test", ["a", "b", "c"]);
	conn.injectfln(":%s 353 %s = #test :a +b @c", origin, testUser.nickName);
	handleClientEvents();
	onNameList.check();

	TestEvent!"onNameListEnd" onNameListEnd;
	onNameListEnd.prepare("#test");
	conn.injectfln(":%s 366 %s #test :End of NAMES list", origin, testUser.nickName);
	handleClientEvents();
	onNameListEnd.check();

	TestEvent!"onMessage" onMessage;
	onMessage.prepare(IrcUser("nick", "user", null), "#test", "hello world");
	conn.injectfln(":nick!user PRIVMSG #test :hello world");
	handleClientEvents();
	onMessage.check();

	onMessage = TestEvent!"onMessage"();
	onMessage.prepare(IrcUser("nick", "user", "host"), "#test", "hi");
	conn.injectfln(":nick!user@host PRIVMSG #test hi");
	handleClientEvents();
	onMessage.check();

	TestEvent!"onNotice" onNotice;
	onNotice.prepare(IrcUser(origin), testUser.nickName, "foo bar");
	conn.injectfln(":%s NOTICE %s :foo bar", origin, testUser.nickName);
	handleClientEvents();
	onNotice.check();

	TestEvent!"onNickChange" onNickChange;
	onNickChange.prepare(testUser, "newNick");
	conn.injectfln(":%s NICK newNick", testUser);
	testUser.nickName = "newNick";
	testUser.nickName = "newNick";
	handleClientEvents();
	onNickChange.check();

	auto otherUser = IrcUser("othernick", "other", "other.org");
	TestEvent!"onJoin" onJoin;
	onJoin.prepare(otherUser, "#test");
	conn.injectfln(":%s JOIN #test", otherUser);
	handleClientEvents();
	onJoin.check();

	TestEvent!"onPart" onPart;
	onPart.prepare(otherUser, "#test");
	conn.injectfln(":%s PART #test", otherUser);
	handleClientEvents();
	onPart.check();

	TestEvent!"onPart" onMePart;
	onMePart.prepare(testUser, "#test");
	client.part("#test");
	conn.assertLine("PART", "#test");
	conn.injectfln(":%s PART #test", testUser);
	handleClientEvents();
	onMePart.check();

	client.join("#test");
	conn.assertLine("JOIN", "#test");

	TestEvent!"onKick" onKick;
	onKick.prepare(testUser, "#test", testUser.nickName, "test reason");
	client.kick("#test", testUser.nickName, "test reason");
	conn.assertLine("KICK", "#test", testUser.nickName, "test reason");
	conn.injectfln(":%s KICK #test %s :test reason", testUser, testUser.nickName);
	handleClientEvents();
	onKick.check();

	auto quittingUser = IrcUser("iquit", "quitter", "quitting.org");
	TestEvent!"onQuit" onQuit;
	onQuit.prepare(quittingUser, "Goodbye!");
	conn.injectfln(":%s QUIT :Goodbye!", quittingUser);
	handleClientEvents();
	onQuit.check();

	// Test line splitting
	// Max message size in unit test mode: PRIVMSG #test :0123456789ABCDEF
	void send(string msg)
	{
		client.send("#test", msg);
	}

	void sendFormatted(string msg)
	{
		client.sendf("#test", "%s", msg);
	}

	foreach(sender; TypeTuple!(send, sendFormatted))
	{
		sender("hello world");
		conn.assertLine("PRIVMSG", "#test", "hello world");

		sender("0123456789ABCDEF");
		conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");

		sender("0123456789ABCDEF0123456789ABCDEF");
		conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");
		conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");

		sender("0123456789ABCDEF0123456789ABCDEFhello");
		conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");
		conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");
		conn.assertLine("PRIVMSG", "#test", "hello");

		sender("hello\nworld");
		conn.assertLine("PRIVMSG", "#test", "hello");
		conn.assertLine("PRIVMSG", "#test", "world");

		sender("\nhello\r\n\rworld");
		conn.assertLine("PRIVMSG", "#test", "hello");
		conn.assertLine("PRIVMSG", "#test", "world");

		sender("hello world\r\n0123456789ABCDEF");
		conn.assertLine("PRIVMSG", "#test", "hello world");
		conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");
	}

	// Test message formatting
	client.sendf("#test", "%01d %02d %03d", 1, 2, 3);
	conn.assertLine("PRIVMSG", "#test", "1 02 003");

	client.sendf("#test", "012%s456789ABCDEF01234567%s9ABCDEF", 3, 8);
	conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");
	conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");

	client.sendf("#test", "abc%sdef%s%sghi", "\r", "\n", "\r\n");
	conn.assertLine("PRIVMSG", "#test", "abc");
	conn.assertLine("PRIVMSG", "#test", "def");
	conn.assertLine("PRIVMSG", "#test", "ghi");

	client.sendf("#test", "0123456789ABC%sEF\nhello\n\r\n", "\n");
	conn.assertLine("PRIVMSG", "#test", "0123456789ABC");
	conn.assertLine("PRIVMSG", "#test", "EF");
	conn.assertLine("PRIVMSG", "#test", "hello");

	// Test range messages
	client.send("#test", only('h', 'e', 'l', 'l', 'o'));
	conn.assertLine("PRIVMSG", "#test", "hello");

	client.send("#test", "日本語"w);
	conn.assertLine("PRIVMSG", "#test", "日本語");

	client.send("#test", "日本語"d);
	conn.assertLine("PRIVMSG", "#test", "日本語");

	client.send("#test", "0123456789".chain("ABCDEF"));
	conn.assertLine("PRIVMSG", "#test", "0123456789ABCDEF");

	client.send("#test", chain("hello", "\r\n", "world"));
	conn.assertLine("PRIVMSG", "#test", "hello");
	conn.assertLine("PRIVMSG", "#test", "world");

	client.send("#test", "hello".repeat(2).joiner);
	conn.assertLine("PRIVMSG", "#test", "hellohello");

	client.quit("test");
	conn.assertLine("QUIT", "test");
}

