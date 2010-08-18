%% -------------------------------------------------------------------
%%
%% riak_kv_bitcask_backend: Bitcask Driver for Riak
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(riak_kv_bitcask_backend).
-behavior(riak_kv_backend).
-author('Andy Gross <andy@basho.com>').
-author('Dave Smith <dizzyd@basho.com>').

-export([start/2,
         stop/1,
         get/2,
         put/3,
         delete/2,
         list/1,
         list_bucket/2,
         fold/3,
         drop/1,
         is_empty/1,
         snapshot_keys/2,
         callback/3]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MERGE_CHECK_INTERVAL, timer:minutes(3)).

start(Partition, _Config) ->

    %% Get the data root directory
    DataDir =
        case application:get_env(bitcask, data_root) of
            {ok, Dir} ->
                Dir;
            _ ->
                riak:stop("bitcask data_root unset, failing")
        end,

    %% Setup actual bitcask dir for this partition
    BitcaskRoot = filename:join([DataDir,
                                 integer_to_list(Partition)]),
    case filelib:ensure_dir(BitcaskRoot) of
        ok ->
            ok;
        {error, Reason} ->
            error_logger:error_msg("Failed to create bitcask dir ~s: ~p\n",
                                   [BitcaskRoot, Reason]),
            riak:stop("riak_kv_bitcask_backend failed to start.")
    end,

    case bitcask:open(BitcaskRoot, [{read_write, true}]) of
        Ref when is_reference(Ref) ->
            schedule_merge(Ref),
            maybe_schedule_sync(Ref),
            {ok, {Ref, BitcaskRoot}};
        {error, Reason2} ->
            {error, Reason2}
    end.


stop({Ref, _}) ->
    bitcask:close(Ref).


get({Ref, _}, BKey) ->
    Key = term_to_binary(BKey),
    case bitcask:get(Ref, Key) of
        {ok, Value} ->
            {ok, Value};
        not_found  ->
            {error, notfound};
        {error, Reason} ->
            {error, Reason}
    end.

put({Ref, _}, BKey, Val) ->
    Key = term_to_binary(BKey),
    case bitcask:put(Ref, Key, Val) of
        ok -> ok;
        {error, Reason} ->
            {error, Reason}
    end.

delete({Ref, _}, BKey) ->
    case bitcask:delete(Ref, term_to_binary(BKey)) of
        ok -> ok;
        {error, Reason} ->
            {error, Reason}
    end.

list({Ref, _}) ->
    case bitcask:list_keys(Ref) of
        KeyList when is_list(KeyList) ->
            [binary_to_term(K) || K <- KeyList];
        Other ->
            Other
    end.

list_bucket(State, {filter, Bucket, Fun}) ->
    [K || {B, K} <- ?MODULE:list(State),
          B =:= Bucket,
          Fun(K)];
list_bucket(State, '_') ->
    [B || {B, _K} <- ?MODULE:list(State)];
list_bucket(State, Bucket) ->
    [K || {B, K} <- ?MODULE:list(State), B =:= Bucket].


fold({Ref, _}, Fun0, Acc0) ->
    %% When folding across the bitcask, the bucket/key tuple must
    %% be decoded. The intermediate binary_to_term call handles this
    %% and yields the expected fun({B, K}, Value, Acc)
    bitcask:fold(Ref,
                 fun(K, V, Acc) ->
                         Fun0(binary_to_term(K), V, Acc)
                 end,
                 Acc0).

drop({Ref, BitcaskRoot}) ->
    %% todo: once bitcask has a more friendly drop function
    %%  of its own, use that instead.
    bitcask:close(Ref),
    {ok, FNs} = file:list_dir(BitcaskRoot),
    [file:delete(filename:join(BitcaskRoot, FN)) || FN <- FNs],
    file:del_dir(BitcaskRoot),
    ok.

is_empty({Ref, _}) ->
    %% Determining if a bitcask is empty requires us to find at least
    %% one value that is NOT a tombstone. Accomplish this by doing a fold
    %% that forcibly bails on the very first k/v encountered.
    F = fun(_K, _V, _Acc0) ->
                throw(found_one_value)
        end,
    case catch(bitcask:fold(Ref, F, undefined)) of
        found_one_value ->
            false;
        _ ->
            true
    end.

callback({Ref, _}, Ref, {sync, SyncInterval}) when is_reference(Ref) ->
    bitcask:sync(Ref),
    schedule_sync(Ref, SyncInterval);
callback({Ref, BitcaskRoot}, Ref, merge_check) when is_reference(Ref) ->
    case bitcask:needs_merge(Ref) of
        {true, Files} ->
            bitcask_merge_worker:merge(BitcaskRoot, [], Files);
        false ->
            ok
    end,
    schedule_merge(Ref);
%% Ignore callbacks for other backends so multi backend works
callback(_State, _Ref, _Msg) ->
    ok.

%% ===================================================================
%% Internal functions
%% ===================================================================

%% @private
%% Schedule sync (if necessary)
maybe_schedule_sync(Ref) when is_reference(Ref) ->
    case application:get_env(bitcask, sync_strategy) of
        {ok, {seconds, Seconds}} ->
            SyncIntervalMs = timer:seconds(Seconds),
            schedule_sync(Ref, SyncIntervalMs);
            %% erlang:send_after(SyncIntervalMs, self(),
            %%                   {?MODULE, {sync, SyncIntervalMs}});
        {ok, none} ->
            ok;
        BadStrategy ->
            error_logger:info_msg("Ignoring invalid bitcask sync strategy: ~p\n",
                                  [BadStrategy]),
            ok
    end.

schedule_sync(Ref, SyncIntervalMs) when is_reference(Ref) ->
    riak_kv_backend:callback_after(SyncIntervalMs, Ref, {sync, SyncIntervalMs}).

schedule_merge(Ref) when is_reference(Ref) ->
    riak_kv_backend:callback_after(?MERGE_CHECK_INTERVAL, Ref, merge_check).

snapshot_keys(Ref, FilterFun) when is_reference(Ref),
                                   is_function(FilterFun) ->
    bitcask_snapshot:snapshot_keys(Ref, FilterFun).


%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

simple_test() ->
    ?assertCmd("rm -rf test/bitcask-backend"),
    application:set_env(bitcask, data_root, "test/bitcask-backend"),
    riak_kv_backend:standard_test(?MODULE, []).

-endif.
