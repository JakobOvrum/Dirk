%%{
    machine irc_common;
 
    crlf = "\r\n";
    separator = " ";
    valid = any -- ("\z" | "\r" | "\n");
    param_valid = valid -- separator -- ":";
    prefix_valid = param_valid -- "@" -- "!";
 
    name = prefix_valid+ >mark %write_name;
    user = prefix_valid+ >mark %write_user;
    host = prefix_valid+ >mark %write_host;
    prefix = (":" name ("!" user)? ("@" host)? separator) $err(prefix_err);
    command = ((digit{3} | alpha+) >mark %write_command) $err(command_err);
    trailing = (separator ":" valid** >mark %write_arg) $err(arg_err);
    middle = (separator param_valid+ >mark %write_arg) $err(arg_err);
    
    gobble_line := (any -- crlf)* crlf @{ fgoto main; };
    line = prefix? command middle* trailing? crlf %write_message;
    main := line* <err(message_err);
}%%