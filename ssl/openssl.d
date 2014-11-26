module ssl.openssl;

import loader.loader;

import core.stdc.config;
import core.stdc.string : strlen;

struct SSL_CTX;
struct SSL;
struct SSL_METHOD;
struct X509_STORE_CTX;

// Constants from Deimos bindings
enum SSL_VERIFY_NONE = 0x00;
enum SSL_ERROR_WANT_READ = 2;
enum SSL_ERROR_WANT_WRITE = 3;
// End of Deimos bindings

extern(C)
{
	alias VerifyCallback = int function(int, X509_STORE_CTX*);

	int function() SSL_library_init_p;
	void function() OPENSSL_add_all_algorithms_noconf_p;
	void function() SSL_load_error_strings_p;
	int function(const SSL *ssl, int ret) SSL_get_error_p;

	char* function(c_ulong e, char* buf) ERR_error_string_p;

	SSL_CTX* function(const(SSL_METHOD)* meth) SSL_CTX_new_p;
	const(SSL_METHOD)* function() SSLv3_client_method_p; /* SSLv3 */

	SSL* function(SSL_CTX* ctx) SSL_new_p;
	int function(SSL* s, int fd) SSL_set_fd_p;
	void function(SSL *s, int mode, VerifyCallback verify_callback) SSL_set_verify_p;
	int function(SSL* ssl) SSL_connect_p;
	int function(SSL* ssl, void* buf, int num) SSL_read_p;
	int function(SSL* ssl, const(void)* buf, int num) SSL_write_p;
}

version(Windows)
{
	immutable libsslNames = ["ssleay32"];
	immutable libcryptoNames = ["libeay32"];
}
else version(Posix)
{
	immutable libsslNames = ["libssl.so.1.0.0", "libssl.so"];
	immutable libcryptoNames = ["libcrypto.so.1.0.0", "libcrypto.so"];
}
else
	static assert(false, "unrecognized platform");

private DynamicLibrary tryLibraries(in string[] names)
{
	if(names.length > 1)
	{
		foreach(name; names[0 .. $ - 1])
		{
			try
				return DynamicLibrary(name);
			catch(DynamicLoaderException) {}
		}
	}
	
	return DynamicLibrary(names[$ - 1]);
}

void loadOpenSSL()
{
	static bool loaded = false;
	if(loaded)
		return;

	auto ssl = tryLibraries(libsslNames);
	ssl.resolve!SSL_library_init_p;
	ssl.resolve!SSL_load_error_strings_p;
	ssl.resolve!SSL_get_error_p;

	ssl.resolve!SSL_CTX_new_p;
	ssl.resolve!SSLv3_client_method_p;

	ssl.resolve!SSL_new_p;
	ssl.resolve!SSL_set_fd_p;
	ssl.resolve!SSL_set_verify_p;
	ssl.resolve!SSL_connect_p;
	ssl.resolve!SSL_read_p;
	ssl.resolve!SSL_write_p;

	auto crypto = tryLibraries(libcryptoNames);
	crypto.resolve!OPENSSL_add_all_algorithms_noconf_p;
	crypto.resolve!ERR_error_string_p;

	SSL_library_init_p();
	OPENSSL_add_all_algorithms_noconf_p();
	SSL_load_error_strings_p();

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
		auto error = SSL_get_error_p(ssl, result);

		// std.socket.wouldHaveBlocked is true when the following errors
		// are reported, so defer to that.
		if(error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE)
		{
			char* zMsg = ERR_error_string_p(error, null);
			auto msg = zMsg[0 .. strlen(zMsg)].idup;
			throw new OpenSSLException(msg, error, file, line);
		}
	}

	return result;
}

