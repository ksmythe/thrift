-module(thrift_socket_transport).

-behaviour(thrift_transport).

-export([new/1,
         new/2,
         write/2, read/2, flush/1, close/1,

         new_protocol_factory/3]).

-record(data, {socket,
               recv_timeout=infinity}).

new(Socket) ->
    new(Socket, []).

new(Socket, Opts) when is_list(Opts) ->
    State =
        case lists:keysearch(recv_timeout, 1, Opts) of
            {value, {recv_timeout, Timeout}}
            when is_integer(Timeout), Timeout > 0 ->
                #data{socket=Socket, recv_timeout=Timeout};
            _ ->
                #data{socket=Socket}
        end,
    thrift_transport:new(?MODULE, State).

%% Data :: iolist()
write(#data{socket = Socket}, Data) ->
    gen_tcp:send(Socket, Data).

read(#data{socket=Socket, recv_timeout=Timeout}, Len)
  when is_integer(Len), Len >= 0 ->
    case gen_tcp:recv(Socket, Len, Timeout) of
        Err = {error, timeout} ->
            error_logger:info_msg("read timeout: peer conn ~p", [inet:peername(Socket)]),
            gen_tcp:close(Socket),
            Err;
        Data -> Data
    end.

%% We can't really flush - everything is flushed when we write
flush(_) ->
    ok.

close(#data{socket = Socket}) ->
    gen_tcp:close(Socket).


%%%% FACTORY GENERATION %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% The following "local" record is filled in by parse_factory_options/2
%% below. These options can be passed to new_protocol_factory/3 in a
%% proplists-style option list. They're parsed like this so it is an O(n)
%% operation instead of O(n^2)
-record(factory_opts, {connect_timeout = infinity,
                       sockopts = [],
                       framed = false,
                       strict_read = true,
                       strict_write = true}).

parse_factory_options([], Opts) ->
    Opts;
parse_factory_options([{strict_read, Bool} | Rest], Opts) when is_boolean(Bool) ->
    parse_factory_options(Rest, Opts#factory_opts{strict_read=Bool});
parse_factory_options([{strict_write, Bool} | Rest], Opts) when is_boolean(Bool) ->
    parse_factory_options(Rest, Opts#factory_opts{strict_write=Bool});
parse_factory_options([{framed, Bool} | Rest], Opts) when is_boolean(Bool) ->
    parse_factory_options(Rest, Opts#factory_opts{framed=Bool});
parse_factory_options([{sockopts, OptList} | Rest], Opts) when is_list(OptList) ->
    parse_factory_options(Rest, Opts#factory_opts{sockopts=OptList});
parse_factory_options([{connect_timeout, TO} | Rest], Opts) when TO =:= infinity; is_integer(TO) ->
    parse_factory_options(Rest, Opts#factory_opts{connect_timeout=TO}).

%%
%% Generates a "protocol factory" function - a fun which returns a Protocol instance.
%% This can be passed to thrift_client:start_link in order to connect to a
%% server over a socket.
%%
new_protocol_factory(Host, Port, Options) ->
    ParsedOpts = parse_factory_options(Options, #factory_opts{}),

    F = fun() ->
                SockOpts = [binary,
                            {packet, 0},
                            {active, false},
                            {nodelay, true} |
                            ParsedOpts#factory_opts.sockopts],
                case catch gen_tcp:connect(Host, Port, SockOpts,
                                           ParsedOpts#factory_opts.connect_timeout) of
                    {ok, Sock} ->
                        {ok, Transport} = thrift_socket_transport:new(Sock),
                        {ok, BufTransport} =
                            case ParsedOpts#factory_opts.framed of
                                true  -> thrift_framed_transport:new(Transport);
                                false -> thrift_buffered_transport:new(Transport)
                            end,
                        thrift_binary_protocol:new(
                          BufTransport,
                          [{strict_read,  ParsedOpts#factory_opts.strict_read},
                           {strict_write, ParsedOpts#factory_opts.strict_write}]);
                    Error  ->
                        Error
                end
        end,
    {ok, F}.
