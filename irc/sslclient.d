module irc.sslclient;

import std.exception;
import std.socket;

import irc.client;

import ssl.openssl;

version(force_ssl_load) shared static this()
{
	loadOpenSSL();
}

private SSL_CTX* sslContext;

void initSslContext()
{
	if(!sslContext)
		sslContext = SSL_CTX_new(SSLv3_client_method());
}

version(force_ssl_load) static this()
{
	initSslContext();
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
		loadOpenSSL();
		initSslContext();

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
