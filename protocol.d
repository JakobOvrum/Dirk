module irc.protocol;

import std.string;


struct IrcLine
{
	const(char)[] prefix; // Optional
	const(char)[] command;
	const(char)[][] parameters;
	
	const(char)[] lastParameter() const @property
	{
		return parameters[$ - 1];
	}
}

bool parse(in char[] raw, out IrcLine line)
{	
	if(raw[0] == ':')
	{
		raw = raw[1..$];
		line.prefix = raw.munch("^ ");
	}
	
	line.command = raw.munch("^ ");
	
	const(char)[] params = raw.munch("^:");
	while(params.length > 0)
		line.parameters ~= params.munch("^ ");
	
	if(raw.length > 0)
		line.parameters ~= raw;
		
	return true;
}

unittest
{
	struct InputOutput
	{
		string input;
		IrcLine output;
		bool valid = true;
	}
	
	InputOutput[] testData = [
		{
			input: "PING 123456",
			output: {command: "PING", parameters: ["123456"]}
		}
	];
	
	foreach(test; testData)
	{
		IrcLine line;
		bool succ = parse(test.input, line);
		assert(test.valid? (succ && test.output == line) : !succ);
	}
}