# Cluster call transaction

## Changelog

* 2021-08-11: @zhongwencool Initial draft

## Abstract

When EMQX updates the cluster resources via HTTP API,  it first updates the local node resources, and then updates all other nodes via RPC Multi Call to ensure the consistency of resources (configuration)  in the cluster.

**In order to ensure consistency, it must ensure that the updates will be be eventually applied on all nodes in the cluster**.

## Motivation

The current solution is to update the resources of the local node successfully, and then RPC calls to update the resources of other nodes synchronously.

Update resources may be lost during the RPC call.

- If there is a network disturbance during RPC, it may cause the RPC to fail.
- If a remote operation to update a resource fails, there is no retry or any other remedy, causing inconsistent configuration in the cluster.
- If multiple updates are performed concurrently, it may happen that node 1 performs updates in order 1, 2, 3, but node 2 updates in order 1, 3, 2. There is no order guarantee.
- Lack of replay. If a node is down for a while, there is a lack of history event replay to catch up with the changes happened during the down time.

## Design

This proposal uses mnesia to record the execution status of MFA, to ensure the consistency of the final resources & data in the cluster.

This proposal is not applicable to high frequency request calls, all updates are performed in strict order.

### mnesia table structure

```erlang
-record(cluster_rpc_mfa, {tnx_id :: pos_integer(), mfa :: mfa(), created_at :: calendar:datetime(), initiator :: node()}).
-record(cluster_rpc_cursor, {node :: node(), tnx_id :: pos_integer()}).
mnesia(boot) ->
    ok = ekka_mnesia:create_table(?CLUSTER_MFA, [
        {type, ordered_set},
        {disc_copies, [node()]},
        {rlog_shard, ?COMMON_SHARD},
        {record_name, cluster_rpc_mfa},
        {attributes, record_info(fields, cluster_rpc_mfa)}]),
    ok = ekka_mnesia:create_table(?CLUSTER_CURSOR, [
        {type, set},
        {disc_copies, [node()]},
        {rlog_shard, ?COMMON_SHARD},
        {record_name, cluster_rpc_cursor},
        {attributes, record_info(fields, cluster_rpc_cursor)}]);
mnesia(copy) ->
    ok = ekka_mnesia:copy_table(cluster_rpc_mfa, disc_copies),
    ok = ekka_mnesia:copy_table(cluster_rpc_cursor, disc_copies).
```

- `tnx_id` is strictly +1 incremental, all executed transactions must be executed in strict order, if there is node 1 executing transaction 1, 2, 3, but node 2 keeps failing in executing transaction 2 after executing transaction 1, it will keep retrying transaction 2 until it succeeds before executing transaction 3.

- `cluster_call_cursor` :   Records the maximum `tnx_id` executed by the node. All transactions less than this id have been executed successfully on this node.
- `cluster_call_mfa`: `ordered_set`:  Records the MFA for each `tnx_id` in pairs. Keep the latest completed 100 records for querying and troubleshooting.

### Flow

1. `emqx_cluster_rpc_handler` register as `gen_server` on each node, subscribes to the mnesia table simple event, and is responsible for the execution of all transactions.

2. `handler` init will catch up latest tnx_id. if node's tnx_id is 5, but latest MFA's tnx_id is 10, it will try to run MFA from 6 to 10 by 5 transactions.

   ```erlang
   init([Node, RetryMs]) ->
       {ok, _} = mnesia:subscribe({table, ?CLUSTER_MFA, simple}),
       {ok, #{node => Node, retry_interval => RetryMs}, {continue, ?CATCH_UP}}.
   
   handle_continue(?CATCH_UP, State) ->
       {noreply, State, catch_up(State)}.
   
   catch_up(#{node := Node, retry_interval := RetryMs} = State) ->
       case transaction(fun get_next_mfa/1, [Node]) of
           {atomic, caught_up} -> ?TIMEOUT;
           {atomic, {still_lagging, NextId, MFA}} ->
               case apply_mfa(NextId, MFA) of
                   ok ->
                       case transaction(fun commit/2, [Node, NextId]) of
                           {atomic, ok} -> catch_up(State);
                           Error ->
                               ?SLOG(error, #{
                                   msg => "mnesia write transaction failed",
                                   node => Node,
                                   nextId => NextId,
                                   error => Error}),
                               RetryMs
                       end;
                   _Error -> RetryMs
               end;
           {aborted, Reason} ->
               ?SLOG(error, #{
                   msg => "get_next_mfa transaction failed",
                   node => Node, error => Reason}),
               RetryMs
       end.
   get_next_mfa(Node) ->
       NextId =
           case mnesia:wread({?CLUSTER_COMMIT, Node}) of
               [] ->
                   LatestId = get_latest_id(),
                   TnxId = max(LatestId - 1, 0),
                   commit(Node, TnxId),
                   ?SLOG(notice, #{
                       msg => "New node first catch up and start commit.",
                       node => Node, tnx_id => TnxId}),
                   TnxId;
               [#cluster_rpc_commit{tnx_id = LastAppliedID}] -> LastAppliedID + 1
           end,
       case mnesia:read(?CLUSTER_MFA, NextId) of
           [] -> caught_up;
           [#cluster_rpc_mfa{mfa = MFA}] -> {still_lagging, NextId, MFA}
       end.
   
   get_latest_id() ->
       case mnesia:last(?CLUSTER_MFA) of
           '$end_of_table' -> 0;
           Id -> Id
       end.
   ```

3. If a new update operation is added, the `handler` will receive a write event of the `cluster_rpc_mfa` table.
   "read the next record" -> "execute action" -> "commit" loop, with iteration triggered by mnesia events. The content of the events could be ignored.

   ```erlang
   handle_info({mnesia_table_event, _}, State) ->
       {noreply, State, catch_up(State)};


4. The initial transaction must be executed in the `emqx_cluster_rpc` process. if this transaction succeeds, the call returns success directly, if the transaction fails, the call aborts with failure.

   ```erlang
   handle_call({initiate, MFA}, _From, State = #{node := Node}) ->
       case transaction(fun init_mfa/2, [Node, MFA]) of
           {atomic, {ok, TnxId}} ->
               {reply, {ok, TnxId}, State, {continue, ?CATCH_UP}};
           {aborted, Reason} ->
               {reply, {error, Reason}, State, {continue, ?CATCH_UP}}
       end;
   
   init_mfa(Node, MFA) ->
       mnesia:write_lock_table(?CLUSTER_MFA),
       LatestId = get_latest_id(),
       ok = do_catch_up_in_one_trans(LatestId, Node),
       TnxId = LatestId + 1,
       mnesia:write(#cluster_rpc_cursor{node = Node, tnx_id = TnxId}),
       mnesia:write(#cluster_rpc_mfa{tnx_id = TnxId, mfa = MFA, initiator = Node, created_at = erlang:localtime()}),
       ok = apply_mfa(MFA).
   
   do_catch_up_in_one_trans(LatestId, Node) ->
       case do_catch_up(LatestId, Node) of
           caught_up -> ok;
           ok -> do_catch_up_in_one_trans(LatestId, Node);
           _ -> mnesia:abort("catch up failed")
       end.

   **Risk point**: If the previous unfinished MFA in the `init_mfa` transaction is executed successfully, but the latest MFA fails and leads to abort,  it will roll back the previous unfinished MFA as well, thus causing the MFA to be executed again later. So MFA must be idempotent.

   If nodes A,B have completed transaction 4, and they are fighting to update transaction 5 at the same time, A finally gets transaction 5 and commits successfully, at this time, B can only update to transaction 6, when the event of transaction 5 has not reached node B, B got transaction 6, it will lead to the error that transaction 6 is executed before transaction 5. So we must check  if there are any uncompleted transactions in transaction 6(`do_catch_up_in_one_trans`).

   In addition to this solution, we can also determine in `init_mfa` that if there are still transactions that have not been applied, then we will return an error directly.

5. Only keep the latest completed 100 records for querying and troubleshooting

6. The MFA function must return ok if it is executed successfully, otherwise mark it as failed and retry later.

   ```erlang
   apply_mfa({M, F, A}) ->
       try erlang:apply(M, F, A)
       catch E:R -> {error, {E, R}}
       end.
   ```

### API Design

```erlang
-spec(emqx_cluster_rpc:call(Nodes,MFA) -> {ok,TnxId}|{error,Reason} when
                          Nodes :: [node()],
                          MFA :: {module(),atom(),[term()]},                          
                          TxnId :: pos_integer()}].  
-spec(emqx_cluster_rpc:reset() -> ok.
-spec(emqx_cluster_rpc:status() -> [#{tnx_id => pos_integer(), mfa => mfa(), 
                                      pending_node => [node()],
                                      initiator => node(),
                                      created_at => localtime()}]).
```

## Configuration Changes

```yaml
node.cluster_call {
    ## Time interval to retry after a failed call
    ##
    ## @doc node.cluster_call.retry_interval
    ## ValueType: Duration
    ## Default: 1s
    retry_interval = 1s
    ## Retain the maximum number of completed transactions (for queries)
    ##
    ## @doc node.cluster_call.max_history
    ## ValueType: Integer
    ## Range: [1, 500]
    ## Default: 100
    max_history = 100
    ## Time interval to clear completed but stale transactions.
    ## Ensure that the number of completed transactions is less than the max_history
    ##
    ## @doc node.cluster_call.cleanup_interval
    ## ValueType: Duration
    ## Default: 5m
    cleanup_interval = 5m
    }
```



## Backwards Compatibility

N/A

## Document Changes

N/A

## Testing Suggestions

The final implementation must include unit test or common test code. If some
more tests such as integration test or benchmarking test that need to be done
manually, list them here.

## Declined Alternatives

Here goes which alternatives were discussed but considered worse than the current.
It's to help people understand how we reached the current state and also to
prevent going through the discussion again when an old alternative is brought
up again in the future.

