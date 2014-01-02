module irc.testing;

version(dirk_unittest):

import std.socket;

import irc.client;
import irc.protocol;

string nickName = "TestNick";
immutable userName = "user";
immutable realName = "Test Name";
auto testUser = IrcUser("TestNick", userName, "test.org");

class TestConnection
{
	private:
	Socket clientSocket, server;
	static static char[512] _lineBuffer;

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
		client.nick = nickName;
		client.userName = userName;
		client.realName = realName;

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
			assert(originator.nick == nickName, `expected nickname "%s", got "%s")`.format(nickName, originator.nick));
			assert(originator.userName == null, `got username, expected none`);
			assert(originator.hostName == null, `got hostname, expected none`);
		}

		if(line.prefix)
		{
			import std.exception : AssertError;

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
	auto conn = new TestConnection();
	auto origin = "testserver";
	auto client = conn.client;

	struct TestEvent(string eventName)
	{
		import std.traits;
		alias Args = ParameterTypeTuple!(typeof(mixin("IrcClient." ~ eventName)[0]));

		void delegate(Args) handler;
		bool prepared = false, ran = false;

		@disable this(this);

		void prepare(Args expectedArgs)
		{
			handler = delegate void(Args args) {
				ran = true;
				assert(args == expectedArgs);
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

	conn.assertLine("NICK", nickName);
	conn.assertLine("USER", userName, null, null, realName);

	TestEvent!"onConnect" onConnect;
	onConnect.prepare();
	conn.injectfln(":%s 001 %s :Welcome to the test server", origin, nickName);
	handleClientEvents();
	onConnect.check();

	client.join("#test");
	conn.assertLine("JOIN", "#test");

	TestEvent!"onSuccessfulJoin" onSuccessfulJoin;
	onSuccessfulJoin.prepare("#test");
	conn.injectfln(":%s JOIN #test", testUser);
	handleClientEvents();
	onSuccessfulJoin.check();

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
	onNotice.prepare(IrcUser(origin), nickName, "foo bar");
	conn.injectfln(":%s NOTICE %s :foo bar", origin, nickName);
	handleClientEvents();
	onNotice.check();

	TestEvent!"onNickChange" onNickChange;
	onNickChange.prepare(testUser, "newNick");
	conn.injectfln(":%s NICK newNick", testUser);
	testUser.nick = "newNick";
	nickName = "newNick";
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

	client.quit("test");
	conn.assertLine("QUIT", "test");
}

void main() {} // TODO: does VisualD support -main yet?
