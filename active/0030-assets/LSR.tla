-------------------------------- MODULE LSR --------------------------------
EXTENDS Sequences, Naturals, TLC
VARIABLES CStores, (* Core storages *)
          RStores, (* Replicant storages *)
          RQueue,  (* Replicant storages async queue *)
          CQueue,  (* Core storages async queue *)
          Chans    (* channels *)
CONSTANT Cores, Replicants, CHs, NONE

CHStates == {NONE, "registered", "aborted", "unregistered", "closed"}

TypeInvariant ==
    /\ Chans \in [CHs -> [loc: Replicants \union {NONE}, \* location of the channel
                          state: CHStates,               \* channel state
                          retry: {3},                    \* left of takeover retries
                          pre: CHs \union {NONE}]]       \* predecessor from best of the knowledge

-----------------------------------------------------------------------------

(* helpers *)

Max(S) ==
    CHOOSE x \in S : \A y \in S : x >= y

MaxOrNone(S) ==
    IF S = {} THEN NONE ELSE Max(S)
    
MaxRVsn(node) == MaxOrNone(RStores[node])

MaxCVsn(node) == MaxOrNone(CStores["c1"]) \* impl core node selection

    
IsMaxInStore(v, store) == \A i \in store : i < v

DoREnqueue(log) == 
            RQueue' = [R \in Replicants |-> Append(RQueue[R], log)]
            
DequeueRQueue(r) == 
            /\ RQueue[r] /= <<>> 
            /\ LET h == Head(RQueue[r]) IN
                RStores' = [ RStores EXCEPT ![r] = RStores[r] \union {h.key} ]     
            /\ RQueue' = [RQueue EXCEPT ![r] = Tail(RQueue[r])]
            /\ UNCHANGED <<CStores, Chans, CQueue>>
            
            
insert_job(ch) == [op |-> "insert", key |-> ch]
del_job(ch) == [op |-> "del", key |-> ch]


DO_TX_COMMIT(c, max_vsn) ==
    /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "Registered" ]
    /\ CStores' = [ node \in DOMAIN CStores |-> {c} \union CStores[node]]
    /\ RQueue' = [ node \in DOMAIN RQueue |-> Append(RQueue[node], insert_job(c))]
    /\ UNCHANGED <<CQueue, RStores>>
    
DO_DIRTY_UNREG(c) ==
    /\ CQueue' = [ node \in DOMAIN CQueue |-> Append(CQueue[node], del_job(c))]
    /\ UNCHANGED <<CQueue, RStores, CStores>>
    
    
NOOP(c) == TRUE
-----------------------------------------------------------------------------

Init == 
    /\ CStores = [ c \in Cores |-> {}]
    /\ RStores = [ r \in Replicants |-> {}]
    /\ CQueue = [ c \in Cores |-> <<>>]
    /\ RQueue = [ r \in Replicants |-> <<>>]
    /\ Chans = [ch \in CHs |-> [loc |-> NONE, state |-> NONE, pre |-> NONE, retry |-> 3]]
 
    
(* CH connect *)
NextCHConnect(c) == 
    \E r \in Replicants:
        /\ Chans[c].loc = NONE 
        /\ Chans' = [Chans EXCEPT ![c].loc = r]
        /\ UNCHANGED <<CStores, RStores, RQueue, CQueue>>

\* Finshed Stage one, New session
DoNewSession(c) == 
    /\ Chans' = [ Chans EXCEPT ![c].pre = NONE, ![c].state = "NewSession" ]
    
\* @TODO takeover session involving other ch
DoTakeoverSession(c) == TRUE
        
DoTakeoverSessionTX(c) == LET ch == Chans[c] max_vsn == MaxCVsn(ch.loc) IN
    /\ max_vsn /= NONE
    /\ IF max_vsn = ch.pre
       THEN /\ DO_TX_COMMIT(c, max_vsn)
       ELSE IF max_vsn < c
            THEN /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "RetryTakeover" ]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
       ELSE 
            /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "Abort" ]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
            
NextCHDirtyReadMax(c) == LET ch == Chans[c] IN
    /\ ch.loc /= NONE /\ ch.state = NONE
    /\ Chans' = [ Chans EXCEPT ![c].pre = MaxRVsn(ch.loc), ![c].state = "DirtyReadMax" ]
    /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
    
NextCHNewSession(c) ==  LET ch == Chans[c] IN
    /\ (ch.state = "DirtyReadMax" /\ ch.pre = NONE) \/ ch.state = "TakeoverFailed" 
    /\ DoNewSession(c)
    /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
    
NextCHTakeoverSessionSuccess(c) == LET ch == Chans[c] IN
    /\ ch.state = "DirtyReadMax" 
    /\ ch.pre /= NONE
    /\ DoTakeoverSession(c)
    /\ Chans' = [ Chans EXCEPT ![c].state = "TakeoverStarted" ]
    /\ UNCHANGED <<CStores, RStores, CQueue, RQueue>>
   
NextCHTakeoverSessionFail(c) ==  LET ch == Chans[c] IN
    /\ ch.state = "DirtyReadMax"
    /\ ch.pre /= NONE
    /\ Chans' = [ Chans EXCEPT ![c].pre = NONE, ![c].state = "TakeoverFailed" ]
    /\ UNCHANGED <<CStores, RStores, CQueue, RQueue>>  

NextCHTakeoverTX(c) == LET ch == Chans[c] IN
    /\ ch.state = "TakeoverStarted" 
    /\ ch.pre /= NONE \* @TODO assert this pre is not NONE when takeover
    /\ DoTakeoverSessionTX(c)
    
NextCHNewTX_NoExisting(c) == LET ch == Chans[c] max_vsn == MaxCVsn(ch.loc) IN
    /\ ch.state = "NewSession" 
    /\ ch.pre = NONE
    /\ max_vsn = NONE
    /\ DO_TX_COMMIT(c, max_vsn)
    
NextCHNewTX_AlreadyExisting(c) == LET ch == Chans[c] max_vsn == MaxCVsn(ch.loc) IN
    /\ ch.state = "NewSession" 
    /\ ch.pre = NONE
    /\ max_vsn /= NONE
    /\ IF max_vsn < c   
       THEN /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "RetryTakeover" ]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
       ELSE 
            /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "Abort" ]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
            
            
\* AssertNoAbort pre > cur
            
 
NextCHRetry(c) == LET ch == Chans[c] max_vsn == MaxCVsn(ch.loc) IN
    /\ ch.state = "RetryTakeover"
    /\ IF ch.retry > 0 
       THEN
            /\ Chans' = [ Chans EXCEPT ![c].state = "DirtyReadMax", ![c].retry = Chans[c].retry - 1]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue >>
       ELSE
            /\ Chans' = [ Chans EXCEPT ![c].state = "Abort" ]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue >>
            
            
  
NextCHAbort(c) == LET ch == Chans[c] IN
    /\ ch.state = "Abort"
    /\ Chans' = [ Chans EXCEPT ![c].state = "offline" ]
    /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>

NextCHNewTX(c) == \/ NextCHNewTX_NoExisting(c)
                  \/ NextCHNewTX_AlreadyExisting(c)

NextCH == \E c \in CHs:
            \/ NextCHConnect(c) \* @TODO move to init
            \/ NextCHDirtyReadMax(c)            \* Step 1:  read local max
            \/ NextCHNewSession(c)              \* Step 2a: New session
            \/ NextCHNewTX(c)                   \* Step 3a: New session commit 
            \/ NextCHTakeoverSessionSuccess(c)  \* Step 2b: Takeover Session success
            \/ NextCHTakeoverTX(c)              \* Step 3b: Takeover Session commit
            \/ NextCHTakeoverSessionFail(c)     \* Step 2b: Takeover Session fail
            \/ NextCHRetry(c)                   \* Step 4a: Maybe retry 
            \/ NextCHAbort(c)                   \* Step 4b: Maybe Abort
            
            
(* Next Actions of replications *)
NextR == \E r \in Replicants: DequeueRQueue(r)

Next == NextCH \/ NextR
Spec == Init /\ [][Next]_<<CStores, RStores, Chans, CQueue, RQueue>>
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E c \in CHs: NextCHConnect(c))
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E r \in Replicants: DequeueRQueue(r))
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E c \in CHs: NextCH)


-----------------------------------------------------------------------------
(***** Invariants and Property *****)
-----------------------------------------------------------------------------

eventuallyNoChanNone == <>~(\E ch \in CHs: Chans[ch].loc = NONE)
eventuallyMaxWin == <>(\E ch \in CHs: LET max == Len(Chans)  IN
                            Chans[max].state = "Registered")

testRQueueAlwaysEmpty == \A r \in Replicants: RStores[r] = {}

testAbortWontHappen == [] (~ \E c \in CHs: ENABLED NextCHAbort(c))


=============================================================================
\* Modification History
\* Last modified Thu Jun 05 15:37:18 CEST 2025 by ezhuwya
\* Created Wed Jun 04 13:38:58 CEST 2025 by ezhuwya
