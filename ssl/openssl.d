module ssl.openssl;

import loader.loader;

import core.stdc.config;
import core.stdc.string : strlen;

struct SSL_CTX;
struct SSL;
struct SSL_METHOD;
struct X509_STORE_CTX;

enum SSL_VERIFY_NONE = 0x00; // From Deimos bindings

extern(C)
{
	alias VerifyCallback = int function(int, X509_STORE_CTX*);

	int function() SSL_library_init;
	void function() OPENSSL_add_all_algorithms_noconf;
	void function() SSL_load_error_strings;
	int function(const SSL *ssl, int ret) SSL_get_error;

	char* function(c_ulong e, char* buf) ERR_error_string;

	SSL_CTX* function(const(SSL_METHOD)* meth) SSL_CTX_new;
	const(SSL_METHOD)* function() SSLv3_client_method; /* SSLv3 */

	SSL* function(SSL_CTX* ctx) SSL_new;
	int function(SSL* s, int fd) SSL_set_fd;
	void function(SSL *s, int mode, VerifyCallback verify_callback) SSL_set_verify;
	int function(SSL* ssl) SSL_connect;
	int function(SSL* ssl,void* buf,int num) SSL_read;
	int function(SSL* ssl,const(void)* buf,int num) SSL_write;


}

void loadOpenSSL()
{
	static bool loaded = false;
	if(loaded)
		return;

	auto ssl = DynamicLibrary("ssleay32");

	ssl.resolve!SSL_library_init;
	ssl.resolve!SSL_load_error_strings;
	ssl.resolve!SSL_get_error;

	ssl.resolve!SSL_CTX_new;
	ssl.resolve!SSLv3_client_method;
	
	ssl.resolve!SSL_new;
	ssl.resolve!SSL_set_fd;
	ssl.resolve!SSL_set_verify;
	ssl.resolve!SSL_connect;
	ssl.resolve!SSL_read;
	ssl.resolve!SSL_write;

	auto lib = DynamicLibrary("libeay32");
	lib.resolve!OPENSSL_add_all_algorithms_noconf;
	lib.resolve!ERR_error_string;

	SSL_library_init();
	OPENSSL_add_all_algorithms_noconf();
	SSL_load_error_strings();

	loaded = true;
}

/**
 * Thrown if an SSL error occurs.
 */
class OpenSSLException : Exception
{
	private:
	int error_;

	public:
	this(string msg, int error, string file = __FILE__, size_t line = __LINE__)
	{
		error_ = error;
		super(msg, file, line);
	}

	int error() @property
	{
		return error_;
	}
}

int sslEnforce(const SSL* ssl, int result, string file = __FILE__, size_t line = __LINE__)
{
	if(result < 0)
	{
		auto error = SSL_get_error(ssl, result);

		char* zMsg = ERR_error_string(error, null);

		auto msg = zMsg[0 .. strlen(zMsg)].idup;

		throw new OpenSSLException(msg, error, file, line);
	}

	return result;
}
