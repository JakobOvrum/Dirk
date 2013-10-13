module irc.testing;

version(dirk_unittest):

import std.socket;

import irc.client;
import irc.protocol;

immutable nickName = "TestNick";
immutable userName = "user";
immutable realName = "Test Name";
IrcUser testUser = IrcUser(nickName, userName, "test.org");

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

	template TestEvent(string eventName)
	{
		import std.traits;
		static bool ran = false;

		alias Args = ParameterTypeTuple!(typeof(mixin("IrcClient." ~ eventName)[0]));

		static void delegate(Args) handler;

		void prepare(Args expectedArgs)
		{
			handler = delegate void(Args args) {
				ran = true;
				assert(args == expectedArgs);
			};

			mixin("client." ~ eventName) ~= handler;
		}

		void check()
		{
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

	alias OnConnect = TestEvent!"onConnect";
	OnConnect.prepare();
	conn.injectfln(":%s 001 %s :Welcome to the test server", origin, nickName);
	handleClientEvents();
	OnConnect.check();

	client.join("#test");
	conn.assertLine("JOIN", "#test");

	alias OnSuccessfulJoin = TestEvent!"onSuccessfulJoin";
	OnSuccessfulJoin.prepare("#test");
	conn.injectfln(":%s JOIN #test", testUser);
	handleClientEvents();
	OnSuccessfulJoin.check();

	client.quit("test");
	conn.assertLine("QUIT", "test");
}

void main() {} // TODO: does VisualD support -main yet?
