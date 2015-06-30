-module(z_server).
-compile(export_all).

-include("definitions.hrl").
-define(Timer, 100).

waitfor_gone(Ident) ->
	case whereis(Ident) of
		undefined -> ok;
		_ ->
			timer:sleep(100),
			waitfor_gone(Ident)
	end.

get_commands() ->
	[
		{"pm", fun pm/5, server},
		{"msg", fun pm/5, server},
		{"age", fun age/5, server},
		{"notes", fun notes/5, server},
		{"notify", fun notify/5, user}
	].

initialise(T) ->
	case file:consult("server.crl") of
		{ok, [{Server, Port, Pwd}]} -> spawn(z_server, sloop, [Server, Port, 45678, Pwd]);
		{error, E} -> logging:log(error, "SERVER", "~p", [E]), error
	end,
	T.

deinitialise(T) ->
	case whereis(z_server) of
		undefined -> ok;
		Pid -> Pid ! stop
	end,
	waitfor_gone(z_server),
	T.

%

pm(_, RT, Ping, [], _) -> {irc, {msg, {RT, [Ping, "Provide a user to PM and a message."]}}};
pm(_, RT, Ping, [_], _) -> {irc, {msg, {RT, [Ping, "Provide a message."]}}};
pm(N, RT, Ping, Params, _) ->
	z_server ! {pm, N, RT, Ping, string:to_lower(hd(Params)), string:join(tl(Params), " ")},
	ok.

notes(_, RT, Ping, [], _) -> {irc, {msg, {RT, [Ping, "Provide a user to find notes for."]}}};
notes(N, RT, Ping, [Key], _) ->
	z_server ! {notes, N, RT, Ping, string:to_lower(Key)},
	ok;
notes(_, RT, Ping, _, _) -> {irc, {msg, {RT, [Ping, "Provide a single key."]}}}.

age(_, RT, Ping, [], _) -> {irc, {msg, {RT, [Ping, "Provide a key to check the age of."]}}};
age(_, RT, Ping, [Key], _) ->
	z_server ! {age, RT, Ping, Key},
	ok;
age(_, RT, Ping, _, _) -> {irc, {msg, {RT, [Ping, "Provide a single key."]}}}.

notify(N, RT, Ping, _, _) ->
	z_server ! {notify, N, RT, Ping},
	ok.

sloop(Svr, Prt, SPrt, Pwd) ->
	case gen_tcp:listen(SPrt, [list, {packet, http}, {active, false}]) of
		{ok, SvrSock} ->
			logging:log(info, "SERVER", "Starting loop."),
			register(z_server, self()),
			loop(SvrSock, Svr, Prt, SPrt, Pwd, sets:new()),
			logging:log(info, "SERVER", "Ending loop."),
			gen_tcp:close(SvrSock);
		{error, Reason} ->
			logging:log(error, "SERVER", "Failed to open listen socket: ~p", [Reason])
	end.

loop(SvrSock, Svr, Prt, SPrt, Pwd, Notify) ->
	case receive
		{pm, Sender, ReplyChannel, ReplyPing, Recipient, Message} ->
			logging:log(info, "SERVER", "sending PM ~s to ~s", [Message, Recipient]),
			Reply = case byond:send(Svr, Prt, io_lib:format("?adminmsg=~s;msg=~s;key=~s;sender=~s", lists:map(fun byond:vencode/1, [Recipient, Message, Pwd, Sender]))) of
				{error, T} -> io_lib:format("Error: ~s", [T]);
				Dict ->
					case orddict:fetch_keys(Dict) of
						["Message Successful"] -> "Sent.";
						[T] -> T
					end
			end,
			core ! {irc, {msg, {ReplyChannel, [ReplyPing, Reply]}}},
			ok;
		{notes, _, ReplyChannel, ReplyPing, Lookup} ->
			logging:log(info, "SERVER", "finding notes for ~s", [Lookup]),
			Reply = case byond:send(Svr, Prt, io_lib:format("?notes=~s;key=~s", lists:map(fun byond:vencode/1, [Lookup, Pwd]))) of
				{error, T} -> io_lib:format("Error: ~s", [T]);
				Dict ->
					case hd(orddict:fetch_keys(Dict)) of
						"No information found on the given key." -> "No information found on the given key.";
						T ->
							os:putenv("sprunge", T),
							X = os:cmd("echo $sprunge | /home/bot32/privatepaste.py --no-tee -e 1800"),
							case X of
								"Pasting...\n" ++ URL -> URL;
								_ -> ["unknown error: ", X]
							end
					end
			end,
			core ! {irc, {msg, {ReplyChannel, [ReplyPing, Reply]}}},
			ok;
		{age, ReplyChannel, ReplyPing, Key} ->
			logging:log(info, "SERVER", "finding age for ~s", [Key]),
			Reply = case byond:send(Svr, Prt, io_lib:format("?age=~s;key=~s", lists:map(fun byond:vencode/1, [Key, Pwd]))) of
				{error, T} -> io_lib:format("Error: ~s", [T]);
				Dict -> ["Age of ", Key, ": ", hd(orddict:fetch_keys(Dict))]
			end,
			core ! {irc, {msg, {ReplyChannel, [ReplyPing, Reply]}}},
			ok;
						
		{notify, Who, ReplyChannel, ReplyPing} ->
			case sets:is_element(string:to_lower(Who), Notify) of
				true ->
					core ! {irc, {msg, {ReplyChannel, [ReplyPing, "You are already on the list to be notified!"]}}},
					ok;
				false ->
					core ! {irc, {msg, {ReplyChannel, [ReplyPing, "You will be notified when the server restarts."]}}},
					{notify, sets:add_element(string:to_lower(Who), Notify)}
			end;
		{notify, T} -> {notify, T};
		stop -> stop
	after
		?Timer ->
			case gen_tcp:accept(SvrSock, ?Timer) of
				{ok, Socket} -> readsock(Socket, Pwd, Notify), ok;
				{error, timeout} -> ok;
				{error, X} -> {error, X}
			end
	end of
		ok ->         loop(SvrSock, Svr, Prt, SPrt, Pwd, Notify);
		{notify,N} ->
			logging:log(info, "SERVER", "setting notify as ~p", [sets:to_list(N)]),
			loop(SvrSock, Svr, Prt, SPrt, Pwd, N);
		stop -> ok;
		E -> logging:log(error, "SERVER", "received unknown status ~p, exiting", [E])
	end.

readsock(Socket, Pwd, Notify) ->
	% timeout specified just to avoid crashing the bot if bad things happen
	case gen_tcp:recv(Socket, 0, 20000) of
		{ok, {http_request, 'GET', URL, _}} ->
			Plist = tl(URL), % a=x;b=y;c=z
			Dict = byond:params2dict(Plist),
			case orddict:find("pwd", Dict) of
				{ok, Pwd} ->
					case {orddict:find("chan", Dict), orddict:find("mesg", Dict)} of
						{{ok, Chan}, {ok, Mesg}} ->
							Msg = re:replace(Mesg, "[\r\n\t]+", " ", [global, {return, list}]),
							logging:log(info, "SERVER", "relaying to ~s: ~s", [Chan, Msg]),
							case string:str(Msg, "Server starting up on ") of
								1 ->
									lists:foreach(fun(T) -> core ! {irc, {msg, {T, Msg}}} end, sets:to_list(Notify)),
									self() ! {notify, sets:new()};
								_ -> ok
							end,
							case string:str(Msg, "A round of ") of
								1 -> lists:foreach(fun(T) -> core ! {irc, {msg, {T, Msg}}} end, sets:to_list(Notify));
								_ -> ok
							end,
							core ! {irc, {msg, {Chan, Msg}}};
						_ -> logging:log(info, "SERVER", "received correctly keyed message with no channel and/or message")
					end;
				{ok, NotPwd} -> logging:log(info, "SERVER", "received incorrect key ~s", [NotPwd]);
				error -> logging:log(info, "SERVER", "received non-keyed message '~s'", [Plist])
			end,
			gen_tcp:send(Socket, "HTTP/1.1 200 OK\r\n\r\n"),
			gen_tcp:close(Socket);
		{error, T} -> logging:log(error, "SERVER", "error in readsock: ~p", [T])
	end.
