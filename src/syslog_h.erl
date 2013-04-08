%%%=============================================================================
%%% Permission to use, copy, modify, and/or distribute this software for any
%%% purpose with or without fee is hereby granted, provided that the above
%%% copyright notice and this permission notice appear in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%%
%%% @doc
%%% The event handler for to be attached to the `error_logger' event manager.
%%% This module will handle all log message, format them and forward them to the
%%% configured protocol handler. Protocol handler must implement the `syslog_h'
%%% behaviour.
%%% @end
%%%=============================================================================
-module(syslog_h).

-behaviour(gen_event).

%% API
-export([attach/1]).

%% gen_event callbacks
-export([init/1,
         handle_event/2,
         handle_call/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("syslog.hrl").

-define(GET_ENV(Property), application:get_env(syslog, Property)).

%%%=============================================================================
%%% callback definitions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% This is the behaviour that must be implemented by protocol backends.
%%------------------------------------------------------------------------------

-callback to_iolist(#syslog_report{}) -> iolist().

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Attach this module as event handler for `error_logger' events. The
%% connection between the event manager and the handler will be supervised by
%% the calling process. The handler will automatically be detached when the
%% calling process exits.
%% @end
%%------------------------------------------------------------------------------
-spec attach(gen_udp:socket()) -> ok | term().
attach(Socket) -> gen_event:add_sup_handler(error_logger, ?MODULE, [Socket]).

%%%=============================================================================
%%% gen_event callbacks
%%%=============================================================================

-record(state, {
          socket          :: gen_udp:socket(),
          msg_queue_limit :: pos_integer(),
          protocol        :: module(),
          facility        :: syslog:facility(),
          error_facility  :: syslog:facility(),
          dest_host       :: inet:ip_address() | inet:hostname(),
          dest_port       :: inet:port_number(),
          hostname        :: string(),
          domain          :: string(),
          appname         :: string(),
          beam_pid        :: string(),
          bom             :: binary()}).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
init([Socket]) ->
    {ok, #state{
            socket          = Socket,
            msg_queue_limit = get_property(msg_queue_limit, ?LIMIT),
            protocol        = get_protocol(get_property(protocol, ?PROTOCOL)),
            facility        = get_property(facility, ?FACILITY),
            error_facility  = get_property(error_facility, ?FACILITY),
            dest_host       = get_property(dest_host, ?DEST_HOST),
            dest_port       = get_property(dest_port, ?DEST_PORT),
            hostname        = get_hostname(),
            domain          = get_domain(),
            appname         = get_appname(),
            beam_pid        = os:getpid(),
            bom             = get_bom()}}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_event({error, _, {Pid, Fmt, Args}}, State) ->
    {ok, send(format_msg(error, Pid, Fmt, Args, State), State)};
handle_event({error_report, _, {Pid, Type, Report}}, State) ->
    {ok, send(format_report(error, Pid, Type, Report, State), State)};
handle_event({warning_msg, _, {Pid, Fmt, Args}}, State) ->
    {ok, send(format_msg(warning, Pid, Fmt, Args, State), State)};
handle_event({warning_report, _, {Pid, Type, Report}}, State) ->
    {ok, send(format_report(warning, Pid, Type, Report, State), State)};
handle_event({info_msg, _, {Pid, Fmt, Args}}, State) ->
    case process_info(self(), message_queue_len) of
        {message_queue_len, Items} when Items < State#state.msg_queue_limit ->
            {ok, send(format_msg(notice, Pid, Fmt, Args, State), State)};
        _ ->
            {ok, State}
    end;
handle_event({info_report, _, {Pid, Type, Report}}, State) ->
    case process_info(self(), message_queue_len) of
        {message_queue_len, Items} when Items < State#state.msg_queue_limit ->
            {ok, send(format_report(notice, Pid, Type, Report, State), State)};
        _ ->
            {ok, State}
    end;
handle_event(_, State) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_call(_Request, State) -> {ok, undef, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
handle_info(_Info, State) -> {ok, State}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
terminate(_Arg, _State) -> ok.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%=============================================================================
%%% internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
format_msg(Severity, Pid, Fmt, Args, State) ->
    (get_report(State))#syslog_report{
      severity  = map_severity(Severity),
      facility  = severity_to_facility(Severity, State),
      timestamp = os:timestamp(),
      pid       = get_pid(Pid),
      msg       = format(Fmt, Args)}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
format_report(_, Pid, crash_report, Report, State) ->
    Timestamp = os:timestamp(),
    Event = {calendar:now_to_local_time(Timestamp),
             {error_report, self(), {Pid, crash_report, Report}}},
    (get_report(State))#syslog_report{
      severity  = map_severity(critical),
      facility  = severity_to_facility(critical, State),
      timestamp = Timestamp,
      pid       = get_pid(Pid),
      msg       = lists:flatten(sasl_report:format_report(fd, all, Event))};
format_report(_, Pid, _, [{application, A}, {started_at, N} | _], State) ->
    (get_report(State))#syslog_report{
      severity  = map_severity(informational),
      facility  = severity_to_facility(informational, State),
      timestamp = os:timestamp(),
      pid       = get_pid(Pid),
      msg       = format("started application ~w on node ~w", [A, N])};
format_report(_, Pid, _, [{application, A}, {exited, R} | _], State) ->
    (get_report(State))#syslog_report{
      severity  = map_severity(error),
      facility  = severity_to_facility(error, State),
      timestamp = os:timestamp(),
      pid       = get_pid(Pid),
      msg       = format("application ~w exited with ~512p", [A, R])};
format_report(_, Pid, progress, Report, State) ->
    Details = proplists:get_value(started, Report, []),
    Child = get_pid(proplists:get_value(pid, Details)),
    Mfargs = proplists:get_value(mfargs, Details),
    (get_report(State))#syslog_report{
      severity  = map_severity(informational),
      facility  = severity_to_facility(informational, State),
      timestamp = os:timestamp(),
      pid       = get_pid(Pid),
      msg       = format("started child ~s using ~512p", [Child, Mfargs])};
format_report(_, Pid, supervisor_report, Report, State) ->
    Timestamp = os:timestamp(),
    Event = {calendar:now_to_local_time(Timestamp),
             {error_report, self(), {Pid, supervisor_report, Report}}},
    (get_report(State))#syslog_report{
      severity  = map_severity(error),
      facility  = severity_to_facility(error, State),
      timestamp = Timestamp,
      pid       = get_pid(Pid),
      msg       = lists:flatten(sasl_report:format_report(fd, all, Event))};
format_report(_, Pid, syslog, [{args, A}, {fmt, F}, {severity, S} | _], State) ->
    (get_report(State))#syslog_report{
      severity  = map_severity(S),
      facility  = severity_to_facility(S, State),
      timestamp = os:timestamp(),
      pid       = get_pid(Pid),
      msg       = format(F, A)};
format_report(Severity, Pid, _Type, Report, State) ->
    (get_report(State))#syslog_report{
      severity  = map_severity(Severity),
      facility  = severity_to_facility(Severity, State),
      timestamp = os:timestamp(),
      pid       = get_pid(Pid),
      msg       = format(Report)}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
send(R = #syslog_report{msg = M}, State) ->
    send([R#syslog_report{msg = L} || L <- string:tokens(M, "\n")], State);
send(Rs, State = #state{protocol = Protocol}) when is_list(Rs) ->
    [send_datagram(Protocol:to_iolist(R), State) || R <- Rs],
    State.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
send_datagram(Data, #state{socket = S, dest_host = H, dest_port = P}) ->
    ok = gen_udp:send(S, H, P, Data).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
format(Fmt, Args) -> lists:flatten(io_lib:format(Fmt, Args)).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
format(Report) -> format("~512p", [Report]).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_report(State) ->
    #syslog_report{
       hostname  = State#state.hostname,
       domain    = State#state.domain,
       appname   = State#state.appname,
       beam_pid  = State#state.beam_pid,
       bom       = State#state.bom}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_hostname()                -> get_hostname(atom_to_list(node())).
get_hostname("nonode@nohost") -> {ok, Hostname} = inet:gethostname(), Hostname;
get_hostname(Node)            -> hd(lists:reverse(string:tokens(Node, "@"))).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_domain()           -> get_domain(string:tokens(get_hostname(), ".")).
get_domain([_])        -> "";
get_domain([_ | Rest]) -> string:join(Rest, ".").

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_appname()                -> get_appname(atom_to_list(node())).
get_appname("nonode@nohost") -> "beam";
get_appname(Node)            -> hd(string:tokens(Node, "@")).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_property(Property, Default) -> get_property_(?GET_ENV(Property), Default).
get_property_({ok, Value}, _)   -> Value;
get_property_(_, Value)         -> Value.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_protocol(rfc5424) -> syslog_rfc5424;
get_protocol(rfc3164) -> syslog_rfc3164.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_bom()           -> get_bom(?GET_ENV(use_rfc5424_bom)).
get_bom({ok, true}) -> unicode:encoding_to_bom(utf8);
get_bom(_)          -> <<>>.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
get_pid(N) when is_atom(N) -> atom_to_list(N);
get_pid(P) when is_pid(P)  -> get_pid(process_info(P, registered_name), P).
get_pid({registered_name, N}, _) -> atom_to_list(N);
get_pid(_, P)                    -> pid_to_list(P).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
severity_to_facility(error,    #state{error_facility = F}) -> map_facility(F);
severity_to_facility(critical, #state{error_facility = F}) -> map_facility(F);
severity_to_facility(_,        #state{facility = F})       -> map_facility(F).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
map_facility(kernel)   -> 0;
map_facility(kern)     -> 0;
map_facility(mail)     -> 2;
map_facility(daemon)   -> 3;
map_facility(auth)     -> 4;
map_facility(syslog)   -> 5;
map_facility(lpr)      -> 6;
map_facility(news)     -> 7;
map_facility(uucp)     -> 8;
map_facility(cron)     -> 9;
map_facility(authpriv) -> 10;
map_facility(ftp)      -> 11;
map_facility(ntp)      -> 12;
map_facility(logaudit) -> 13;
map_facility(logalert) -> 14;
map_facility(clock)    -> 15;
map_facility(local0)   -> 16;
map_facility(local1)   -> 17;
map_facility(local2)   -> 18;
map_facility(local3)   -> 19;
map_facility(local4)   -> 20;
map_facility(local5)   -> 21;
map_facility(local6)   -> 22;
map_facility(local7)   -> 23.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
map_severity(emergency)     -> 0;
map_severity(alert)         -> 1;
map_severity(critical)      -> 2;
map_severity(error)         -> 3;
map_severity(warning)       -> 4;
map_severity(notice)        -> 5;
map_severity(informational) -> 6;
map_severity(debug)         -> 7.

%%%=============================================================================
%%% TESTS
%%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

get_hostname_test() ->
    {ok, InetReturn} = inet:gethostname(),
    ?assertEqual(InetReturn,        get_hostname("nonode@nohost")),
    ?assertEqual("hostname",        get_hostname("nodename@hostname")),
    ?assertEqual("hostname.domain", get_hostname("nodename@hostname.domain")).

get_domain_test() ->
    ?assertEqual("",          get_domain(string:tokens("host", "."))),
    ?assertEqual("domain",    get_domain(string:tokens("host.domain", "."))),
    ?assertEqual("domain.de", get_domain(string:tokens("host.domain.de", "."))).

get_appname_test() ->
    ?assertEqual("beam",     get_appname("nonode@nohost")),
    ?assertEqual("nodename", get_appname("nodename@hostname")),
    ?assertEqual("nodename", get_appname("nodename@hostname.dom.ain")).

get_pid_test() ->
    ?assertEqual("init", get_pid(init)),
    ?assertEqual("init", get_pid(whereis(init))),
    ?assertEqual(pid_to_list(self()), get_pid(self())).

-endif. %% TEST