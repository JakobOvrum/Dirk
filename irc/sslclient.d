module irc.sslclient;

import std.exception;
import std.socket;

import irc.client;

import ssl.openssl;

shared static this()
{
	loadOpenSSL();

	SSL_library_init();
	OPENSSL_add_all_algorithms_noconf();
	SSL_load_error_strings();
}

private SSL_CTX* sslContext;

static this()
{
	sslContext = SSL_CTX_new(SSLv3_client_method());
}

/**
 * Represents a secure IRC client connection.
 * See_Also:
 *   $(DPREF client, IrcClient)
 */
class SslIrcClient : IrcClient
{
	private:
	SSL* ssl;

	public:

	/**
	* Create a new unconnected IRC client.
	* See_Also:
	*   $(DPREF client, IrcClient.this)
	*/
	this(){}

	protected override:
	Socket createConnection(InternetAddress serverAddress)
	{
		auto socket = new TcpSocket(serverAddress);

		ssl = SSL_new(sslContext);

		SSL_set_fd(ssl, socket.handle);

		sslAssert(ssl, SSL_connect(ssl));

		return socket;
	}

	size_t rawRead(void[] buffer)
	{
		auto result = sslAssert(ssl, SSL_read(ssl, buffer.ptr, buffer.length));
		return result;
	}

	size_t rawWrite(in void[] data)
	{
		auto result = sslAssert(ssl, SSL_write(ssl, data.ptr, data.length));
		return result;
	}
}
