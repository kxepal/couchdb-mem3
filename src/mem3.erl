%%% membership module
%%%
%%% State of the gen_server is a #mem record
%%%
%%% Nodes and Gossip are the same thing, and are a list of three-tuples like:
%%%
%%%  [ {Pos,NodeName,Options} | _ ]
%%%
%%%  Position is 1-based incrementing in order of node joining
%%%
%%%  Options is a proplist, with [{hints, [Part1|_]}] denoting that the node
%%%   is responsible for the extra partitions too.
%%%
%%% TODO: dialyzer type specs
%%%
-module(mem3).
-author('brad@cloudant.com').

-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1, stop/0, stop/1]).
-export([join/2, clock/0, state/0]).
-export([partitions/0, fullmap/0]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% includes
-include("../include/config.hrl").
-include("../include/common.hrl").


%%====================================================================
%% API
%%====================================================================

start_link() ->
    start_link([]).


start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).


stop() ->
    stop(?MODULE).


stop(Server) ->
    gen_server:cast(Server, stop).


join(JoinType, Nodes) ->
    gen_server:call(?MODULE, {join, JoinType, Nodes}).


clock() ->
    gen_server:call(?MODULE, clock).


state() ->
    gen_server:call(?MODULE, state).


%% @doc retrieve the primary partition map.  This is a list of partitions and
%%      their corresponding primary node, no replication partner nodes.
partitions() ->
  ets_pmap().


%% @doc retrieve the full partition map, like above, but including replication
%%      partner nodes.  List should number 2^Q * N
fullmap() ->
  lists:keysort(2, ets_fullmap()).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%% start up membership server
init(Args) ->
    process_flag(trap_exit,true),
    Config = get_config(Args),
    Test = proplists:get_value(test, Args),
    OldState = read_latest_state_file(Test, Config),
    State = handle_init(OldState),
    {ok, State#mem{args=Args}}.


%% new node joining to this node
handle_call({join, JoinType, ExtNodes}, _From,
            State = #mem{args=Args}) ->
    Config = get_config(Args),
    NewState = handle_join(JoinType, ExtNodes, State, Config),
    {reply, ok, NewState};

%% clock
handle_call(clock, _From, State = #mem{clock=Clock}) ->
    {reply, Clock, State};

%% state
handle_call(state, _From, State) ->
    {reply, State, State};

%% ignored call
handle_call(Msg, _From, State) ->
    showroom_log:message(info, "membership: ignored call: ~p", [Msg]),
    {reply, ignored, State}.


%% stop
handle_cast(stop, State) ->
    {stop, normal, State};

%% ignored cast
handle_cast(Msg, State) ->
    showroom_log:message(info, "membership: ignored cast: ~p", [Msg]),
    {noreply, State}.


%% @doc handle nodedown messages because we have
%%      net_kernel:monitor_nodes(true)
handle_info({nodedown, Node}, State) ->
    showroom_log:message(alert, "membership: nodedown from ~p", [Node]),
    {noreply, State};

%% @doc handle nodeup messages because we have
%%      net_kernel:monitor_nodes(true)
handle_info({nodeup, Node}, State) ->
    showroom_log:message(alert, "membership: nodeup Node: ~p", [Node]),
    {noreply, State};

%% ignored info
handle_info(Info, State) ->
    showroom_log:message(info, "membership: ignored info: ~p", [Info]),
    {noreply, State}.


% terminate
terminate(_Reason, _State) ->
    ok.


% ignored code change
code_change(OldVsn, State, _Extra) ->
    io:format("Unknown Old Version~nOldVsn: ~p~nState : ~p~n", [OldVsn, State]),
    {ok, State}.


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @doc if Args has config use it, otherwise call configuration module
%%      most times Args will have config during testing runs
get_config(Args) ->
    case proplists:get_value(config, Args) of
    undefined -> configuration:get_config();
    Any -> Any
    end.


% we could be automatically:
%  1. rejoining a cluster after some downtime
%
% we could be manually:
%  2. beginning a cluster with only this node
%  3. joining a cluster as a new node
%  4. replacing a node in an existing cluster

handle_init(nil) ->
    showroom_log:message(info, "membership: membership server starting...", []),
    net_kernel:monitor_nodes(true),
    Table = init_ets_table(),
    Node = node(),
    Nodes = [{0, Node, []}],
    Clock = vector_clock:create(Node),
    #mem{node=Node, nodes=Nodes, clock=Clock, ets=Table};

handle_init(_OldState) ->
    ?debugHere,
    % there's an old state, let's try to rejoin automatically
    %  but only if we can compare our old state to all other
    %  available nodes and get a match... otherwise get a human involved
    % TODO implement me
    Table = init_ets_table(),
    #mem{ets=Table}.


%% handle join activities, return NewState
handle_join(first, ExtNodes, #mem{node=Node, clock=Clock} = State, Config) ->
    {Pmap, Fullmap} = create_maps(Config, ExtNodes),
    update_ets(Pmap, Fullmap),
    NewClock = vector_clock:increment(Node, Clock),
    State#mem{nodes=ExtNodes, clock=NewClock};

handle_join(new, _ExtNodes, _State, _Config) ->
    ok;

handle_join(replace, [_OldNode | _], _State, _Config) ->
    ok;

handle_join(JoinType, _, _, _) ->
    showroom_log:message(info, "membership: unknown join type: ~p", [JoinType]),
    {error, {unknown_join_type, JoinType}}.


%% @doc find the latest state file on disk
find_latest_state_filename(Config) ->
    Dir = Config#config.directory,
    case file:list_dir(Dir) of
    {ok, Filenames} ->
        Timestamps = [list_to_integer(TS) || {"state", TS} <-
           [list_to_tuple(string:tokens(FN, ".")) || FN <- Filenames]],
        SortedTimestamps = lists:reverse(lists:sort(Timestamps)),
        case SortedTimestamps of
        [Latest | _] ->
            {ok, Dir ++ "/state." ++ integer_to_list(Latest)};
        _ ->
            throw({error, not_found})
        end;
    {error, Reason} ->
        throw({error, Reason})
    end.


%% (Test, Config)
read_latest_state_file(true, _) ->
    nil;
read_latest_state_file(_, Config) ->
    try
        {ok, File} = find_latest_state_filename(Config),
        case file:consult(File) of
        {ok, #mem{}=State} -> State;
        _Else -> throw({error, bad_mem_state_file})
        end
    catch
        _:Error ->
            showroom_log:message(info, "membership: ~p", [Error]),
            nil
    end.


%% @doc given Config and a list of Nodes, construct a {Pmap,Fullmap}
create_maps(#config{q=Q} = Config, Nodes) ->
    [{_,FirstNode,_}|_] = Nodes,
    Fun = fun({_Pos, Node, Options}, Map) ->
        Hints = proplists:get_value(hints, Options),
        {ok, NewMap} = partitions:join(Node, Map, Hints),
        NewMap
    end,
    Acc0 = partitions:create_partitions(Q, FirstNode),
    Pmap = lists:foldl(Fun, Acc0, lists:keysort(1, Nodes)),
    {Pmap, make_fullmap(Pmap, Config)}.


%% @doc construct a table with all partitions, with the primary node and all
%%      replication partner nodes as well.
make_fullmap(PMap, Config) ->
  {Nodes, _Parts} = lists:unzip(PMap),
  NodeParts = lists:flatmap(
    fun({Node,Part}) ->
        Partners = replication:partners(Node, lists:usort(Nodes), Config),
        PartnerList = [{Partner, Part, partner} || Partner <- Partners],
        [{Node, Part, primary} | PartnerList]
    end, PMap),
  NodeParts.


%% ets table helper functions
init_ets_table() ->
    Table = list_to_atom(lists:concat(["mem_", atom_to_list(node())])),
    ets:new(Table, [public, set, named_table]),
    Table.


ets_name(Node) ->
    list_to_atom(lists:concat(["mem_", atom_to_list(Node)])).


update_ets(Pmap, Fullmap) ->
    Table = ets_name(node()),
    ets:insert(Table, {pmap, Pmap}),
    ets:insert(Table, {fullmap, Fullmap}).


ets_pmap() ->
  [{pmap, PMap}] = ets:lookup(ets_name(node()), pmap),
  PMap.


ets_fullmap() ->
  [{fullmap, FullMap}] = ets:lookup(ets_name(node()), fullmap),
  FullMap.