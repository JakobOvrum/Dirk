module ssl.openssl;

import loader.loader;

import core.stdc.config;

struct SSL_CTX;
struct SSL;
struct SSL_METHOD;

extern(C)
{
	int function() SSL_library_init;
	void function() OPENSSL_add_all_algorithms_noconf;
	void function() SSL_load_error_strings;

	char* function(c_ulong e, char* buf) ERR_error_string;

	SSL_CTX* function(const(SSL_METHOD)* meth) SSL_CTX_new;
	const(SSL_METHOD)* function() SSLv3_client_method; /* SSLv3 */

	SSL* function(SSL_CTX* ctx) SSL_new;
	int function(SSL* s, int fd) SSL_set_fd;
	int function(SSL* ssl) SSL_connect;
	int function(SSL* ssl,void* buf,int num) SSL_read;
	int function(SSL* ssl,const(void)* buf,int num) SSL_write;
}

void loadOpenSSL()
{
	static bool opened = false;
	if(opened)
		return;

	auto ssl = DynamicLibrary("ssleay32");

	ssl.resolve!SSL_library_init;
	ssl.resolve!SSL_load_error_strings;

	ssl.resolve!SSL_CTX_new;
	ssl.resolve!SSLv3_client_method;
	
	ssl.resolve!SSL_new;
	ssl.resolve!SSL_set_fd;
	ssl.resolve!SSL_connect;
	ssl.resolve!SSL_read;
	ssl.resolve!SSL_write;

	auto lib = DynamicLibrary("libeay32");
	lib.resolve!OPENSSL_add_all_algorithms_noconf;
	lib.resolve!ERR_error_string;

	opened = true;
}
