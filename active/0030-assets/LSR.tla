-------------------------------- MODULE LSR --------------------------------
EXTENDS Sequences, Naturals, TLC, FiniteSets
VARIABLES CStores, (* Core storages *)
          RStores, (* Replicant storages *)
          RQueue,  (* Replicant storages async queue *)
          CQueue,  (* Core storages async queue *)
          Chans    (* channels *)
CONSTANT Cores, Replicants, CHs, NONE

CHStates == {NONE, "DirtyReadMax", "NewSession", "TakeoverStarted", "Tookover", "TakeoverFailed", "RetryTakeover", "Registered", "Abort", "Terminating", "Offline", "Owned", "PartlyOwned"}

TypeInvariant ==
    /\ Chans \in [CHs -> [loc: Replicants \union {NONE}, \* location of the channel
                          state: CHStates,               \* channel state
                          retry: (0..3),                 \* left of takeover retries
                          pre: CHs \union {NONE}]]       \* predecessor from best of the knowledge
    /\ CStores \in [ Cores -> SUBSET CHs ]
    /\ RStores \in [ Replicants -> SUBSET CHs ]
    /\ RQueue \in [ Replicants -> Seq([ op: {"insert", "del"} , key: CHs]) ]
    /\ CQueue \in [ Cores -> Seq([ op: {"insert", "del"} , key: CHs]) ]

-----------------------------------------------------------------------------
(* helpers *)

Max(S) ==
    CHOOSE x \in S : \A y \in S \ {x} : x > y

MaxOrNone(S) ==
    IF S = {} THEN NONE ELSE Max(S)
    
MaxRVsn(node) == MaxOrNone(RStores[node])

MaxCVsn(node) == MaxOrNone(CStores["c1"]) \* @TODO impl core node selection

IsMaxInStore(v, store) == \A i \in store : i < v

DoREnqueue(log) == 
            RQueue' = [R \in Replicants |-> Append(RQueue[R], log)]
            
DequeueRQueue(r) == 
            /\ RQueue[r] /= <<>> 
            /\ LET h == Head(RQueue[r]) IN
                IF h.op = "insert" THEN
                    RStores' = [ RStores EXCEPT ![r] = RStores[r] \union {h.key} ]
                ELSE
                    RStores' = [ RStores EXCEPT ![r] = RStores[r] \ {h.key} ]      
            /\ RQueue' = [RQueue EXCEPT ![r] = Tail(RQueue[r])]
            /\ UNCHANGED <<CStores, Chans, CQueue>>
            
            
DequeueCQueue(n) == 
            /\ CQueue[n] /= <<>> 
            /\ LET h == Head(CQueue[n]) IN
                IF h.op = "insert" THEN
                    CStores' = [ CStores EXCEPT ![n] = CStores[n] \union {h.key} ]
                ELSE
                    CStores' = [ CStores EXCEPT ![n] = CStores[n] \ {h.key} ]      
            /\ CQueue' = [CQueue EXCEPT ![n] = Tail(CQueue[n])]
            /\ UNCHANGED <<RStores, Chans, RQueue>>
            
            
insert_job(ch) == [op |-> "insert", key |-> ch]
del_job(ch) == [op |-> "del", key |-> ch]


DO_TX_COMMIT(c, max_vsn) ==
    /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "Registered"]
    /\ CStores' = [ node \in DOMAIN CStores |-> {c} \union CStores[node]]
    /\ RQueue' = [ node \in DOMAIN RQueue |-> Append(RQueue[node], insert_job(c))]
    /\ UNCHANGED <<CQueue, RStores>>
    
DO_DIRTY_UNREG(c) ==
    /\ CQueue' = [ node \in DOMAIN CQueue |-> Append(CQueue[node], del_job(c))]
    /\ UNCHANGED <<CQueue, RStores, CStores>>
    
-----------------------------------------------------------------------------
(* Init State *)

Init == 
    /\ CStores = [ c \in Cores |-> {}]
    /\ RStores = [ r \in Replicants |-> {}]
    /\ CQueue = [ c \in Cores |-> <<>>]
    /\ RQueue = [ r \in Replicants |-> <<>>]
    /\ Chans \in [CHs -> [loc: Replicants, state: {NONE}, pre: {NONE}, retry: {3}]]

-----------------------------------------------------------------------------
(* Dos *)  



DoTakeoverSession(c) == LET ch == Chans[c] IN \* Takeover with dirty data, risk to takeover the wrong session 
    /\ Chans' = [Chans EXCEPT ![ch.pre].state = "Tookover", ![c].state = "TakeoverStarted"]
    /\ UNCHANGED <<CStores, RStores, CQueue, RQueue>>
        
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

-----------------------------------------------------------------------------
(* Actions *)      
NextCHDirtyReadMax(c) == LET ch == Chans[c] IN \* Dirty read local max 
    /\ ch.loc /= NONE /\ ch.state = NONE
    /\ Chans' = [ Chans EXCEPT ![c].pre = MaxRVsn(ch.loc), ![c].state = "DirtyReadMax" ]
    /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
    
NextCHNewSession(c) == LET ch == Chans[c] IN \* Start new session
    /\ (ch.state = "DirtyReadMax" /\ ch.pre = NONE) \/ ch.state = "TakeoverFailed" 
    /\ Chans' = [ Chans EXCEPT ![c].pre = NONE, ![c].state = "NewSession" ]
    /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
    
NextCHTakeoverSessionSuccess(c) == LET ch == Chans[c] IN 
    /\ (ch.state = "DirtyReadMax" \/ ch.state = "RetryTakeover")
    /\ ch.pre /= NONE
    /\ ch.pre < c
    /\ DoTakeoverSession(c)
   
NextCHTakeoverSessionFail(c) ==  LET ch == Chans[c] IN
    /\ (ch.state = "DirtyReadMax" \/ ch.state = "RetryTakeover")
    /\ ch.pre /= NONE
    /\ Chans' = [ Chans EXCEPT ![c].pre = NONE, ![c].state = "TakeoverFailed" ]
    /\ UNCHANGED <<CStores, RStores, CQueue, RQueue>>  

NextCHTakeoverTX(c) == LET ch == Chans[c] IN
    /\ ch.state = "TakeoverStarted" 
    /\ ch.pre /= NONE 
    /\ DoTakeoverSessionTX(c)
    
NextCHNewTX_NoExisting(c) == LET ch == Chans[c] max_vsn == MaxCVsn(ch.loc) IN
    /\ ch.state = "DirtyReadMax" 
    /\ ch.pre = NONE
    /\ max_vsn = NONE
    /\ DO_TX_COMMIT(c, max_vsn)
    
NextCHNewTX_AlreadyExisting(c) == LET ch == Chans[c] max_vsn == MaxCVsn(ch.loc) IN
    /\ ch.state = "DirtyReadMax" 
    /\ ch.pre = NONE
    /\ max_vsn /= NONE
    /\ IF max_vsn < c   
       THEN /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "RetryTakeover" ]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
       ELSE 
            /\ Chans' = [ Chans EXCEPT ![c].pre = max_vsn, ![c].state = "Abort" ]
            /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>

NextCHTakeoverEndSuccess(c) == LET ch == Chans[c] IN
    /\ ch.state = "Registered"
    /\ ch.pre /= NONE
    /\ Chans[ch.pre].state = "Tookover"
    /\ Chans' = [ Chans EXCEPT ![ch.pre].state = "Terminating", ![c].state = "Owned"]
    /\ UNCHANGED <<CStores, RStores, CQueue, RQueue >>
    
    
NextCHTakeoverEndFail(c) == LET ch == Chans[c] IN
    /\ ch.state = "Registered"
    /\ ch.pre /= NONE
    /\ Chans[ch.pre].state = "Tookover"
    /\ Chans' = [ Chans EXCEPT ![ch.pre].state = "Terminating", ![c].state = "PartlyOwned"]
    /\ UNCHANGED <<CStores, RStores, CQueue, RQueue >>                  
 
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
    /\ Chans' = [ Chans EXCEPT ![c].state = "Offline" ]
    /\ UNCHANGED << CStores, RStores, CQueue, RQueue>>
    
    
NextCHTerminating(c) == LET ch == Chans[c] IN
    /\ ch.state = "Terminating"
    /\ CQueue' = [ node \in DOMAIN CQueue |-> Append(CQueue[node], del_job(c) )]
    /\ Chans' = [ Chans EXCEPT ![c].state = "Offline" ]
    /\ UNCHANGED <<CStores, RStores, RQueue >>


NextCHNewTX(c) == \/ NextCHNewTX_NoExisting(c)
                  \/ NextCHNewTX_AlreadyExisting(c)

NextCH == \E c \in CHs:
            \/ NextCHDirtyReadMax(c)            \* Step 1:  Dirty read max from local
            \/ NextCHNewSession(c)              \* Step 2a: New session
            \/ NextCHNewTX(c)                   \* Step 3a: New session commit 
            \/ NextCHTakeoverSessionSuccess(c)  \* Step 2b: Takeover Session success
            \/ NextCHTakeoverTX(c)              \* Step 3b: Takeover Session commit
            \/ NextCHTakeoverSessionFail(c)     \* Step 2b: Takeover Session fail
            \/ NextCHRetry(c)                   \* Step 4a: Maybe retry 
            \/ NextCHAbort(c)                   \* Step 4b: Maybe Abort
            \/ NextCHTakeoverEndSuccess(c)      \* Step 5a:  Takeover end
            \/ NextCHTakeoverEndFail(c)      \* Step 5b:  Takeover end failed
            \/ NextCHTerminating(c)             \* Step 6:  Terminating
            
(* Next Actions of replications *)
NextR == \/  (\E node \in Replicants: DequeueRQueue(node))
         \/  (\E node \in Cores: DequeueCQueue(node))

Next == NextCH \/ NextR
Spec == Init /\ [][Next]_<<CStores, RStores, Chans, CQueue, RQueue>>
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E r \in Replicants: DequeueRQueue(r))
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E n \in Cores: DequeueCQueue(n))
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E c \in CHs: NextCHTakeoverEndSuccess(c))
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E c \in CHs: NextCHTerminating(c))
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E c \in CHs: NextCHNewSession(c))
             /\ WF_<<CStores, RStores, CQueue, RQueue, Chans>>(\E c \in CHs: NextCHDirtyReadMax(c))
             
-----------------------------------------------------------------------------
(***** Invariants and Property *****)
-----------------------------------------------------------------------------

\* New ch cannot be takenover by old ch.
assertOldNeverWin ==  ~\E ch \in CHs: Chans[ch].pre /= NONE /\ Chans[ch].pre > ch /\ Chans[ch].state = "Registered"

\* No double registration
assertNoDouble == ~\E ch1, ch2 \in CHs: Chans[ch1].state = "Registered" /\ Chans[ch2].state = "Registered" /\ ch1 /= ch2

\* Never takeover own session
assertNotMe == ~ \E ch \in CHs: ch = Chans[ch].pre

\* No takeover NONE
assertNotTakeoverNone == ~ \E ch \in CHs: Chans[ch].state = "TakeoverStarted" /\  Chans[ch].pre = NONE


\* Property: if max chan is registered, it remains registered. 
eventuallyRegistered == <>[][\E ch \in CHs: ch = Max(CHs) /\ Chans[ch].state = "Owned" /\ \A o \in CHs \ {ch}: Chans[o].state = "Offline"]_<<CStores, RStores, CQueue, RQueue, Chans>>



\* State Predicates that ensures check coverage
\* below are the ones should be violated.
testRStoresAlwaysEmpty == \A r \in Replicants: RStores[r] = {}
testAbortWontHappen == [] (\E c \in CHs: ENABLED NextCHAbort(c))

=============================================================================
\* Modification History
\* Last modified Tue Jun 10 18:10:46 CEST 2025 by ezhuwya
\* Created Wed Jun 04 13:38:58 CEST 2025 by ezhuwya
