module eventloop.interfaces;

import std.socket : Socket;

interface SocketReady
{
	public:
	enum EventType { read = 0b01, write = 0b10 }
	EventType eventType() @property pure nothrow @safe @nogc;
	Socket socket() @property pure nothrow @safe @nogc;
	bool onReady(); // Return true if socket was closed
}

