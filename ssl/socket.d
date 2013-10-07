module irc.sslclient;

import std.exception;
import std.socket;

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
* Represents a secure TCP socket using SSLv3.
*/
class SslSocket : Socket
{
	private:
	SSL* ssl;

	public:
	/**
	* Create a new unconnected and blocking SSL socket.
	* See_Also:
	*   $(DPREF client, IrcClient.this)
	*/
	this(AddressFamily af)
	{
		loadOpenSSL();
		initSslContext();

		super(af, SocketType.STREAM, ProtocolType.TCP);

		ssl = SSL_new(sslContext);
		SSL_set_fd(ssl, super.handle);
		SSL_set_verify(ssl, SSL_VERIFY_NONE, null);
	}

	override:
	void connect(Address to)
	{
		super.connect(to);
		sslEnforce(ssl, SSL_connect(ssl));
	}

	ptrdiff_t receive(void[] buf)
	{
		return receive(buf, SocketFlags.NONE);
	}

	ptrdiff_t receive(void[] buf, SocketFlags flags)
	{
		auto result = sslEnforce(ssl, SSL_read(ssl, buf.ptr, cast(int)buf.length));
		return cast(ptrdiff_t)result;
	}

	ptrdiff_t send(const(void)[] buf)
	{
		return send(buf, SocketFlags.NONE);
	}

	ptrdiff_t send(const(void)[] buf, SocketFlags flags)
	{
		auto result = sslEnforce(ssl, SSL_write(ssl, buf.ptr, cast(int)buf.length));
		return cast(ptrdiff_t)result;
	}

	// TODO: What about sendTo? Throwing stub?
}
