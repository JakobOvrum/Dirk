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

class SSLException : Exception
{
	this(string msg, Throwable next = null, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line, next);
	}
}

class SslIrcClient : IrcClient
{
	private:
	SSL* ssl;

	protected override:
	Socket createConnection(InternetAddress serverAddress)
	{
		auto socket = new TcpSocket(serverAddress);

		ssl = SSL_new(sslContext);

		SSL_set_fd(ssl, socket.handle);

		enforce(SSL_connect(ssl) != -1, new SSLException("connect"));

		return socket;
	}

	size_t rawRead(void[] buffer)
	{
		return SSL_read(ssl, buffer.ptr, buffer.length);
	}

	size_t rawWrite(in void[] data)
	{
		return SSL_write(ssl, data.ptr, data.length);
	}
}
