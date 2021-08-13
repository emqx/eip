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
-define(CLUSTER_MFA, emqx_cluster_call_mfa).
-define(CLUSTER_CURSOR, emqx_cluster_call_cursor).
-record(cluster_call_mfa, {tnx_id :: pos_integer(), mfa :: mfa(), created_at :: pos_integer(), initiator :: node()}).
-record(cluster_call_cursor, {node :: node(), tnx_id :: intger()}).
mnesia(boot) ->
    ok = ekka_mnesia:create_table(?CLUSTER_MFA, [
        {type, ordered_set},
        {disc_copies, [node()]},
        {local_content, true},
        {record_name, activated_alarm},
        {attributes, record_info(fields, cluster_call_mfa)}]),
    ok = ekka_mnesia:create_table(?CLUSTER_CURSOR, [
        {type, set},
        {disc_copies, [node()]},
        {local_content, true},
        {record_name, cluster_tnx_id},
        {attributes, record_info(fields, cluster_call_cursor)}]);
mnesia(copy) ->
    ok = ekka_mnesia:copy_table(cluster_call_mfa, disc_copies),
    ok = ekka_mnesia:copy_table(cluster_call_cursor, disc_copies).
```

- `tnx_id` is strictly +1 incremental, all executed transactions must be executed in strict order, if there is node 1 executing transaction 1, 2, 3, but node 2 keeps failing in executing transaction 2 after executing transaction 1, it will keep retrying transaction 2 until it succeeds before executing transaction 3.

- `cluster_call_cursor` :   Records the maximum `tnx_id` executed by the node. All transactions less than this id have been executed successfully on this node.
- `cluster_call_mfa`: Records the MFA for each `tnx_id` in pairs. Keep the latest completed 100 records for querying and doubleshooting.

### Flow

1. `emqx_cluster_rpc_handler` register on each node, subscribes to the mnesia table simple event, and is responsible for the execution of all transactions.

2. `handler` init will catch up latest tnx_id. if node's tnx_id is 5, but latest MFA's tnx_id is 10, it will try to run MFA from 6 to 10 by 5 transactions.

   ```erlang
   catch_up() ->
       case transaction(fun() -> mnesia:last(?CLUSTER_MFA) end) of
           {atomic, LastTnxId} ->
               catch_up(node(), LastTnxId);
           {aborted, Reason} ->
               retry_catch_up_later(Reason)
       end.
   
   catch_up(Node, ToTnxId) ->
       case transaction(fun() -> do_catch_up(Node, ToTnxId) end) of
           {atomic, caught_up} -> ok;
           {atomic, still_lagging} -> catch_up(Node, ToTnxId);
           {aborted, Reason} -> retry_catch_up_later(Reason)
       end.
   
   do_catch_up(Node, ToTnxId) ->
       case mnesia:wread({?CLUSTER_CURSOR, Node}) of
           [] -> caught_up;
           [#cluster_call_cursor{tnx_id = DoneTnxId}] when ToTnxId =< DoneTnxId -> caught_up;
           [Rec = #cluster_call_cursor{tnx_id = DoneTnxId}] ->
               CurTnxId = DoneTnxId + 1,
               mnesia:write(Rec#cluster_call_cursor{tnx_id = CurTnxId}),
               [#cluster_call_mfa{mfa = MFA}] = mnesia:read(?CLUSTER_MFA, CurTnxId),
               apply_mfa(Node, MFA)
       end.
   ```

3. If a new update operation is added, the `handler` will receive a write event of the `cluster_call_mfa` table.
   When  `EventTxnId = DoneTnxId+1`, i.e. we have finished  transaction 4 and received the notification of transaction 5, we will execute transaction 5 directly, if we receive transaction 6, we will do nothing and let `catch_up` catch up from transaction 5.

   ```erlang
   handle_info({write, MFARec, _ActivityId}, State) ->
       Node = node(),
       case transaction(fun() -> handle_table_write_event(Node, MFARec) end) of
           {atomic, catch_up} -> {noreply, State, {continue, catch_up}};
           {abort, _Reason} -> {noreply, State, {continue, catch_up}};
           {atomic, ok} -> {noreply, State, ?TIMEOUT}
       end.
   
   handle_table_write_event(Node, #cluster_call_mfa{tnx_id = EventTnxId, mfa = MFA}) ->
       DoneTnxId =
           case mnesia:wread({?CLUSTER_CURSOR, Node}) of
               [] -> EventTnxId - 1;
               [#cluster_call_cursor{tnx_id = TnxId}] -> TnxId
           end,
       case EventTnxId =:= DoneTnxId + 1 of
           false -> catch_up; %$% catch up latest id in catch_up/0
           true ->
               mnesia:write(#cluster_call_cursor{tnx_id = EventTnxId, node = Node}),
               apply_mfa(Node, MFA)
       end.
   ```

   

4. The first transaction must be executed in the `emqx_cluster_trans` process. if this transaction succeeds, the call returns success directly, if the transaction fails, the call aborts with failure.

   ```erlang
   commit(Node, MFA) ->
       case catch_up() of
           retry -> {error, "catch up failed"};
           ok ->
               Trans = fun() -> apply_to_commit(Node, MFA) end,
               transaction(Trans)
       end.
   apply_to_commit(Node, MFA) ->
       mnesia:write_lock_table(?CLUSTER_MFA),
       #cluster_call_cursor{tnx_id = LastDoneId} = mnesia:read(?CLUSTER_CURSOR, Node),
       #cluster_call_mfa{tnx_id = LatestId} = mnesia:last(?CLUSTER_MFA),
       ok = do_catch_up_in_one_trans(LatestId, LastDoneId, Node),
       TnxId = LatestId + 1,
       mnesia:write(#cluster_call_cursor{node = Node, tnx_id = TnxId}),
       mnesia:write(#cluster_call_mfa{tnx_id = TnxId, mfa = MFA, initiator = Node, created_at = erlang:localtime()}),
       apply_mfa(Node, MFA).
   
   do_catch_up_in_one_trans(LatestId, LatestId, _Node) -> ok;
   do_catch_up_in_one_trans(LatestId, LastDoneId, Node)when LatestId > LastDoneId ->
       ToTnxId = LastDoneId + 1,
       do_catch_up(Node, ToTnxId),
       do_catch_up_in_one_trans(Node, LatestId, ToTnxId).  
   ```

   **Risk point**: If the previous unfinished MFA in the `apply_to_commit` transaction is executed successfully, but the latest MFA fails and leads to abort,  it will roll back the previous unfinished MFA as well, thus causing the MFA to be executed again later. So MFA must be idempotent.

5. Because all ekka's transactions execute on core node, but the MFA should execute on all node. So we must do MFA with RPC:

   ```erlang
   apply_mfa(Node, {M, F, A}) ->
       %% TODO log
       try rpc:call(Node, M, F, A, 5 * 60 * 1000) of
           ok -> ok;
           {error, Reason} -> mnesia:abort({Node, Reason})
       catch E:R -> mnesia:abort({Node, E, R})
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

N/A.

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

