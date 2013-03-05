module irc.linebuffer;

import irc.exception;

import std.exception;
import core.stdc.string : memmove;

struct LineBuffer
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
