module irc.linebuffer;

import irc.exception;

import std.exception;
import std.socket;
import core.stdc.string : memmove;

debug(Dirk) static import std.stdio;

struct IncomingLineBuffer
{
	private:
	char[] buffer;
	size_t lineStart, bufferPos;
	void delegate(in char[] line) onReceivedLine;

	public:
	this(char[] buffer, void delegate(in char[] line) onReceivedLine)
	{
		this.buffer = buffer;
		this.onReceivedLine = onReceivedLine;
	}

	/// End of the current line.
	size_t position() @property
	{
		return bufferPos;
	}

	/// Notify that n number of bytes have been committed after the current position.
	/// Call with $(D n = 0) to invoke the callback for any lines that were skipped
	/// due to an exception being thrown during a previous commit.
	void commit(size_t n)
	{
		auto nextBufferPos = bufferPos + n;

		if(nextBufferPos == buffer.length)
		{
			bufferPos = nextBufferPos;
			nextBufferPos = moveDown();
		}

		foreach(i; bufferPos .. nextBufferPos)
		{
			if(buffer[i] == '\n')
			{
				auto line = buffer[lineStart .. i];

				if(line.length > 0 && line[$ - 1] == '\r')
					--line.length; // Skip \r

				lineStart = i + 1; // Skip \n

				// If onReceivedLine throws, we want to just skip
				// the the current line, leaving the next lines
				// to be parsed on the next commit.
				bufferPos = lineStart;

				onReceivedLine(line);
			}
		}

		bufferPos = nextBufferPos;
	}

	private:
	size_t moveDown()
	{
		enforceEx!IrcParseErrorException(lineStart != 0, "line too long for buffer");

		auto length = bufferPos - lineStart;
		memmove(buffer.ptr, buffer.ptr + lineStart, length);
		lineStart = 0;
		bufferPos = 0;

		return length;
	}
}

struct OutgoingLineBuffer
{
	private:
	Socket socket;

	version(unittest)
		char["PRIVMSG #test :0123456789ABCDEF\r\n".length] lineBuffer;
	else
		char[IRC_MAX_LEN] lineBuffer = void;

	char[] _messageBuffer, bufferTail;

	public:
	@disable this();
	@disable this(this);

	this(Socket socket, in char[] command, in char[] target)
	{
		this.socket = socket;
		lineBuffer[0 .. command.length] = command;
		immutable targetStart = command.length + 1;
		lineBuffer[command.length .. targetStart] = ' ';
		lineBuffer[targetStart .. targetStart + target.length] = target;
		immutable messageStart = targetStart + target.length + 2;
		lineBuffer[targetStart + target.length .. messageStart] = " :";
		this._messageBuffer = lineBuffer[messageStart .. $ - 2];
		this.bufferTail = _messageBuffer;
	}

	size_t capacity() @property
	{
		return bufferTail.length;
	}

	bool hasMessage() @property
	{
		return bufferTail.length != _messageBuffer.length;
	}

	char[] messageBuffer() @property
	{
		return this._messageBuffer;
	}

	void commit(size_t i)
	{
		bufferTail = bufferTail[i .. $];
	}

	void consume(ref const(char)[] source, size_t n)
	{
		bufferTail[0 .. n] = source[0 .. n];
		bufferTail = bufferTail[n .. $];
		source = source[n .. $];
	}

	void flush()
	{
		immutable fullLength = lineBuffer.length - bufferTail.length;
		immutable sansNewlineLength = fullLength - 2;
		lineBuffer[sansNewlineLength .. fullLength] = "\r\n";
		debug(Dirk) std.stdio.writefln(`<< "%s" (length: %s)`, lineBuffer[0 .. sansNewlineLength], sansNewlineLength);
		socket.send(lineBuffer[0 .. fullLength]);
		bufferTail = _messageBuffer;
	}
}

