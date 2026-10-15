# MQTT Component Model

## Changelog

* 2026-09-09: Initial draft.

## Abstract

This EIP applies the component, dependency, effect, and recovery ideas from [A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512) to MQTT clients. It proposes an EMQX plugin and MQTT wire conventions for governing customer components. It does not change the architecture of EMQX itself.

A component declares which topic resources it provides and which topic resources it requires. The plugin validates those declarations, resolves dependencies, controls activation, and records the operations that must be reversed when an activation ends.

The plugin governs resource identity and lifetime. It does not interpret application payloads or model the physical devices behind them.

## Motivation

### What the paper describes

The paper addresses dynamic composition along two dimensions. Temporal composability means that removing a component removes the effects it contributed to the managed context. Spatial composability means that a component declares what it requires from other components and reacts when those resources appear, disappear, or change provider.

The paper represents a component with three parts:

- A set of keys it requires.
- A set of keys it may provide.
- A sequence of context operations paired with inverse operations.

The runtime activates a component only when its required keys resolve. During activation, it records the concrete providers that satisfy those requirements and accumulates the inverses of the component's effects. When a requirement stops resolving, the runtime withdraws the component's provisions and executes its inverses. It keeps a departing provider available until its committed dependents finish cleanup when the provider is still reachable.

The paper does not derive inverses or prove arbitrary operations commutative. Resource authors define operations with valid inverses and ensure that effects performed by independent components do not interfere. The calculus then shows that dependency ordering, last-in-first-out recovery within a component, and commutativity between independent components preserve the managed context under dynamic activation and removal.

This framework retains that structure but places the managed context at the MQTT boundary instead of inside one process.

### Why MQTT is a useful boundary

Cordis mediates interactions through an in-process context object. For independently implemented IoT components, the MQTT broker is a natural equivalent boundary. Components already identify communication endpoints with topics, publish operations as messages, expose durable values as retained messages, and identify their runtime presence through authenticated connections.

The reserved topic namespaces give the paper's abstract keys concrete forms:

| Paper concept | MQTT representation |
|---|---|
| Key | A declared `$state/...`, `$service/...`, or `$reg/...` topic contract |
| Provision | An installed retained value, service handler, or registry handler |
| Dependency access | An authorized subscription or publication through a committed binding |
| Effect | A retained mutation, service operation, or registry entry |
| Inverse | Retained restoration, retained deletion, or service retraction |

Topics provide stable, language-neutral names. Publications separate an operation's transport from its application semantics. The plugin can therefore authenticate the caller, resolve the target provider, assign an effect identity, enforce confinement, and record cleanup while leaving the operation payload opaque.

This is a good boundary for effects visible through MQTT. It covers resource admission, broker-retained state, registrations, and operations implemented by cooperating providers. It does not cover unreported local state, out-of-band communication, or the physical world. A component receives the framework's guarantees only for interactions that pass through the managed namespaces and obey their contracts.

MQTT components appear, disappear, reconnect, and change dependencies at runtime. A useful component framework must answer two questions:

1. Which components may run with the resources currently available?
2. Which effects must be removed when a component can no longer run?

Dependency declarations answer the first question. Activation-scoped inverse operations answer the second.

The core lifecycle rule is to separate logical availability from physical lifetime. When a provider starts leaving, the plugin immediately prevents new components from binding to it. Existing dependents retain their committed bindings while they stop and clean up. The provider removes its physical resources only after those dependents finish, when that remains possible.

### Why publications fit commutative effects

A key property that enables component composability in the paper is effect commutativity. Effects are operations on resources. Effects from independent components commute when changing their execution order does not change the observable result.

MQTT makes the independence of these operations apparent to component developers. Requests from different components arrive as separate publications rather than as calls within a shared execution flow. A developer can therefore see that their relative order must not be assumed and can design the resource to tolerate valid interleavings or make required ordering explicit in the resource contract.

Each publication is an immutable description of one action. Independently developed components can publish actions without sharing memory, object references, or direct connections.

For operations `A` and `B`, a service may promise:

```text
apply(A); apply(B)       ~= apply(B); apply(A)
retract(A); apply(B)     ~= apply(B); retract(A)
retract(A); retract(B)   ~= retract(B); retract(A)
```

The service then reaches an equivalent state regardless of how MQTT deliveries from different components are interleaved. The plugin does not need to establish a total order between independent components.

The model still imposes a causal order within one effect. The plugin sends `apply(E)` before `retract(E)` and never sends another `apply(E)` afterward. Commutativity governs interleavings between distinct effect IDs, not the two operations of one effect.

Examples include tagged set updates, identified counter deltas, independently identified registrations, and writes to disjoint map entries. A provider may publish the resulting materialized view separately through retained `$state/...` topics.

Publishing itself does not make an operation commutative. The service provider defines the operation algebra and promises the required laws. Absolute assignment, ordered-list insertion, and irreversible physical commands remain order-sensitive unless their contracts define suitable retraction and ordering semantics.

## Design

### Terms and identities

| Term | Meaning |
|---|---|
| Component | A customer MQTT client participating in the framework |
| Component ID | Stable component type or logical name |
| Instance ID | Stable identity of one deployed component instance |
| Connection epoch | Identity of one MQTT connection incarnation |
| Activation | One period during which an instance may perform business operations |
| Activation ID | Unique identity of that activation period |
| Resource key | A declared `$state`, `$service`, or `$reg` topic contract |
| Provider | The component that declares and installs a resource key |
| Dependent | A component that declares a requirement on a resource key |
| Provision | Authority to install a resource declared in `provides` |
| Requirement | Requested access to a resource declared in `requires` |
| Effect ID | Plugin-assigned identity of one managed service operation |

An activation is not an MQTT connection. A component may stay connected while waiting for dependencies, running, draining, and waiting to run again. Each return to active service creates a new activation ID.

The connection epoch prevents a delayed Will or stale connection event from affecting a replacement connection. The activation ID prevents delayed business operations or cleanup from affecting a later activation on the same connection.

The plugin owns these identities. It may expose them as reserved MQTT User Properties, but clients cannot assert or replace their canonical values.

### Declarations and confinement

Each component has an explicit manifest. This example is illustrative; it does not fix the eventual manifest syntax.

```yaml
component: switch
instance: switch-1

provides:
  - kind: service
    key: $service/switch/1

requires:
  - kind: state
    key: $state/lamp/1/contract
    access: read

  - kind: service
    key: $service/lamp/1/control

  - kind: registry
    key: $reg/lamp/1/controllers
    access: [register, observe]
```

Declarations are not inferred from traffic. An MQTT operation must conform to an existing declaration; performing the operation cannot grant the declaration retroactively.

The confinement rules are:

- A component may install only resources listed in `provides`.
- A component may access only resources listed in `requires`.
- A requirement states the permitted access mode.
- A component may not use a wildcard to escape its declared topic scope.
- A client may not publish to plugin-generated internal topics or reserved User Properties.
- Provider declarations for the same logical resource must not conflict or overlap unless the resource contract explicitly supports it.

One component provides each logical resource key. Multiple components may depend on that key. Exclusive provision does not imply that operations performed by those dependents commute.

### Declared, installed, and available provisions

A declared provision grants authority to provide a resource. It does not make that resource available.

A provision moves through three relevant states:

| State | Meaning |
|---|---|
| Declared | The manifest permits the component to provide the key |
| Installed | The component created the backing subscription, handler, or retained value |
| Available | The installed provision belongs to the current active provider activation and may satisfy requirements |

The installation condition depends on the resource kind:

- A `$state` value is installed when its retained message exists.
- A `$service` is installed when its apply and retract subscriptions and handlers are ready.
- A `$reg` space is installed when its registry subscription and handler are ready.

The plugin exposes an installed provision as available only when the component has reported readiness, its own hard requirements are satisfied, and its activation is current.

### Topic model

| Namespace | Provider operation | Dependent operation | MQTT persistence |
|---|---|---|---|
| `$state/X` | Publish the retained value | Subscribe and read | Retained |
| `$service/X` | Subscribe to apply and retract operations | Publish an opaque command | Non-retained |
| `$reg/X` | Subscribe to registry entries | Register, observe, or both | Plugin-managed retained entries |

System lifecycle topics are separate from these resources. Publishing readiness or receiving an activation notification neither provides nor requires an application resource.

### State resources

A `$state` resource exposes retained data owned by its provider.

```text
Provider P:
    PROVIDES $state/X
    PUBLISH RETAIN $state/X

Dependent C:
    REQUIRES $state/X with read access
    SUBSCRIBE $state/X
```

Only the provider may write, replace, or delete the retained message. A dependent may subscribe and read, but it may not write the topic merely because it requires the value.

The payload is opaque to the plugin. Typical values include configuration, a protocol contract, metadata, and reported state.

#### Reversal

The plugin treats an authorized retained mutation as a broker-side reversible effect:

```text
Forward: write retained message M at topic T
Inverse: restore the preceding retained message at T
         or delete T if no retained message preceded the write
```

The inverse restores the relevant MQTT application-message state, not only the payload. It must not restart an expired message's original expiry interval.

Repeated writes by one activation are reversed in last-in-first-out order. A stale inverse may not overwrite state belonging to a newer activation.

A retained write is reversible as broker state. It does not erase copies already delivered to subscribers or consequences produced from those copies.

### Service resources

A `$service` resource accepts operations from components that depend on its provider. In this model, each accepted command creates one activation-scoped effect.

The provider installs one compound service contract:

```text
Provider P:
    PROVIDES $service/X
    SUBSCRIBE $service/X/apply/+
    SUBSCRIBE $service/X/retract/+
```

The dependent publishes an opaque command to the logical base topic:

```text
Dependent C:
    REQUIRES $service/X
    PUBLISH $service/X
```

#### Apply

The plugin processes the base publication as follows:

1. Check that C has a current activation and a committed binding to `$service/X`.
2. Allocate a fresh effect ID.
3. Record the effect ID, owner activation, and provider activation.
4. Suppress the base publication.
5. Forward the original payload to the provider's apply topic.

```text
Topic: $service/X/apply/<effect-id>
Payload: <original opaque command>
RETAIN: 0
User Properties:
    component-activation = <dependent activation>
    provider-activation = <committed provider activation>
```

The plugin must record the effect before forwarding it. Otherwise, a failure could leave an applied operation with no record from which to issue cleanup.

Each publication is a new effect unless the dependent supplies a request identity through an agreed property such as MQTT Correlation Data. A retry that represents the same logical request must reuse that request identity.

#### Retract

When the dependent explicitly releases the effect or its activation ends, the plugin publishes:

```text
Topic: $service/X/retract/<effect-id>
Payload: <empty>
RETAIN: 0
User Properties:
    component-activation = <original dependent activation>
    provider-activation = <committed provider activation>
```

The empty payload is sufficient because the provider retains enough information to retract the effect by ID. The provider defines what retraction means for the application operation.

The plugin sends apply and retract for one effect from the same Erlang channel process to the same provider channel process. Erlang sender-to-recipient signal ordering therefore preserves:

```text
apply(E) < retract(E)
```

The provider processes those messages serially for the effect. The plugin never reuses an effect ID or emits another apply after retract. Recovery and journal replay must preserve the same causal order.

The provider implements this effect state machine:

```text
absent  -- apply(E)   --> applied
applied -- apply(E)   --> applied
applied -- retract(E) --> absent
absent  -- retract(E) --> absent
```

The last transition is an idempotent no-op for a duplicate retract or an apply that failed without creating an effect. It does not create a tombstone. An apply after retract is a framework protocol violation and is excluded by channel ordering and the plugin journal.

The required behavior is:

- Duplicate apply while the effect is active does not create another effect.
- Duplicate retract is harmless.
- Retract removes only the named effect.
- The provider may discard the effect record after retract completes.
- Application-level acknowledgements distinguish applied, retracted, failed, and unknown outcomes.

An MQTT acknowledgement confirms protocol progress. It does not confirm that the provider applied or retracted the operation.

#### Commutativity contract

For distinct effect IDs `E` and `F`, a composable service promises observational equivalence under reordering:

```text
apply(E); apply(F)       ~= apply(F); apply(E)
retract(E); apply(F)     ~= apply(F); retract(E)
retract(E); retract(F)   ~= retract(F); retract(E)
```

Apply and retract for the same effect do not commute. Their order is fixed by the per-effect causal guarantee.

The plugin cannot verify these laws because it treats operation payloads and provider state as opaque. The service author carries the same obligation that a coeffect provider carries in the paper.

A service that cannot provide these laws may still be useful, but it does not receive the framework's order-independent recovery guarantee. Physical effects may provide only compensation or a safe-state transition rather than exact reversal.

### Registry resources

A `$reg` resource is a retained registry space provided by one component and populated by components that depend on it.

```text
Registry provider P:
    PROVIDES $reg/X
    SUBSCRIBE $reg/X/#
```

A dependent may request either or both access modes:

| Access | MQTT operation | Meaning |
|---|---|---|
| `register` | Publish `$reg/X` | Maintain this activation's record in the registry |
| `observe` | Subscribe `$reg/X/#` | Observe the current registry entries |

The manifest determines the role. A dependent subscribing as an observer does not become another registry provider. Its subscription is safe because the plugin has already established its dependency on the declared provider.

#### Registration

A dependent registers by publishing an opaque record to the virtual base topic:

```text
Dependent C:
    REQUIRES $reg/X with register access
    PUBLISH $reg/X
    Payload: <opaque record>
```

The plugin validates the committed binding, suppresses the base publication, and materializes a retained entry:

```text
Topic: $reg/X/<dependent-instance>
Payload: <original opaque record>
RETAIN: 1
User Properties:
    component-activation = <dependent activation>
    registry-activation = <committed registry-provider activation>
```

Only the plugin may publish or delete generated registry entries. A dependent cannot select another component's suffix. When replicas are possible, the suffix identifies the component instance rather than only its component type.

Republishing `$reg/X` during the same activation updates that activation's existing entry. If one activation may own several records, the plugin adds a record ID:

```text
$reg/X/<dependent-instance>/<record-id>
```

#### Registration reversal

The registration is a broker-side reversible effect:

```text
Forward: create the retained entry owned by activation A of dependent C
Inverse: delete that entry if it is still owned by activation A of dependent C
```

The ownership check prevents cleanup from an old activation from deleting a replacement activation's entry at the same stable topic.

Different dependents occupy different entries. Their registration, update, and removal operations therefore do not interfere:

```text
register(A); register(B) ~= register(B); register(A)
remove(A); register(B)   ~= register(B); remove(A)
```

This is the paper's table-of-registrations pattern. The registry provider owns the table contract. Each dependent activation owns one independently removable entry inside it.

#### Observation and membership

Any dependent with `observe` access may subscribe to the generated entries. Observation alone creates a dependency on the registry provider, not on every component that owns an entry.

A component that requires particular members must declare a membership condition separately. Examples include an exact set of instance IDs, at least `N` entries, or another contract-defined predicate. The plugin records the selected member activations in the component's committed view.

### Dependency resolution

The plugin maintains two views for each activation:

- The target view contains the provider activations that are selectable now.
- The committed view contains the provider activations selected when this activation began.

A component activates only when each hard requirement resolves according to its contract. The committed view records provider activation identities, not only logical topic names or payloads.

Provider replacement changes the binding even if the new provider uses the same topics and publishes identical values. The default response is to deactivate the old consumer activation and create a new activation with fresh bindings.

The hard dependency graph must be acyclic. A component that observes a resource without requiring it for activation may declare a soft or advisory requirement instead.

### Readiness and lifecycle

Each component maintains a system-topic subscription for lifecycle notifications. System topic names are separate from application resources and remain available while the component is inactive.

The control exchange is:

```text
Component -> plugin: ready
Plugin -> component: activated
Plugin -> component: deactivated
Component -> plugin: cleanup_complete
```

`ready` means that the component has installed and prepared its declared provisions. It does not claim that its requirements are satisfied.

The activation condition is:

```text
component is ready
and all hard requirements are available
and the component is administratively enabled
```

`deactivated` means that the activation has lost ordinary business authority and must stop accepting or initiating new work. It does not mean that cleanup has completed.

Lifecycle messages identify the activation and carry monotonic generations. A delayed readiness or cleanup message cannot affect a newer activation.

### Withdrawal and cleanup ordering

Logical withdrawal must happen before destructive cleanup.

For a dependency chain:

```text
scene -> switch -> lamp
```

where the arrow means "depends on," loss of the lamp produces this sequence:

1. Remove the lamp from the target view so no new activation can acquire it.
2. Withdraw the switch and scene provisions from new use.
3. Deactivate and clean up the scene.
4. Deactivate and clean up the switch.
5. Finish destructive cleanup of the lamp, if it is still reachable.

The ordering concerns cleanup completion, not only notification order. A provider keeps its service and registry subscriptions available to committed dependents while they retract service effects and remove registry entries.

If a provider crashes, the plugin cannot preserve it for cleanup. The plugin still withdraws it, rejects further operations from affected activations, reverses broker-owned effects, and records client-side cleanup as failed or unknown where necessary.

### Effect classes

| Forward effect | Recorded inverse | Executor |
|---|---|---|
| Write `$state/X` retained message | Restore or delete the preceding retained message | Plugin |
| Apply `$service/X` effect | Publish `$service/X/retract/<effect-id>` | Plugin and service provider |
| Create `$reg/X` entry | Delete the activation-owned retained entry | Plugin |
| Install service or registry subscription | Remove the subscription after dependent cleanup | Provider component |
| Perform a physical action | Contract-defined compensation or safe-state action | Device or service provider |

Effects within one activation are reversed in last-in-first-out order when they do not otherwise commute.

The lifecycle supplies ordering between a provider's installation and its dependents' use. Operations performed by sibling dependents on one service must commute, be isolated, or accept a weaker guarantee. The framework does not repair an arbitrary noncommutative operation.

### Authorization matrix

| MQTT operation | Required declaration or authority |
|---|---|
| Publish retained `$state/X` | Provide `$state/X` |
| Subscribe `$state/X` | Require `$state/X` with read access |
| Subscribe `$service/X/apply/+` and `retract/+` | Provide `$service/X` |
| Publish `$service/X` | Require `$service/X` through a committed binding |
| Publish internal service apply or retract topics | Plugin only |
| Subscribe `$reg/X/#` as registry owner | Provide `$reg/X` |
| Publish `$reg/X` | Require `$reg/X` with register access |
| Subscribe `$reg/X/#` as observer | Require `$reg/X` with observe access |
| Publish generated `$reg/X/...` entries | Plugin only |
| Write reserved activation User Properties | Plugin only |

Authorization is checked against the authenticated instance, current activation, manifest, and committed provider binding.

### Core invariants

The model depends on these invariants:

1. At most one activation is current for an instance.
2. A stale connection epoch or activation cannot advertise resources or perform operations.
3. A component accesses only resources and modes declared in its manifest.
4. A declared provision is not selectable until it is installed and its provider is active.
5. Every dependent activation binds to concrete provider activations.
6. Withdrawal from the target view precedes destructive cleanup.
7. A graceful provider remains available to committed dependents until their cleanup completes.
8. Every accepted service operation has a unique effect ID and an owning activation.
9. Apply precedes retract for each effect, and the plugin never sends apply afterward.
10. Retracting an absent effect is an idempotent no-op.
11. Every generated registry entry has one owning dependent activation.
12. Cleanup from an old activation cannot remove state belonging to a replacement activation.
13. Service commutativity and retraction laws are explicit provider obligations.

### Guarantee boundary

The plugin can strongly govern broker-owned state and admission:

- It can reject undeclared or stale operations.
- It can prevent new bindings to a withdrawn provider.
- It can restore or delete managed retained messages.
- It can delete managed registry entries.
- It can issue every recorded service retraction.

The plugin cannot erase an MQTT message already delivered or a physical consequence already produced. A service retraction establishes the recovery behavior promised by that service. It does not make physical history equivalent to a history in which the operation never occurred.

MQTT delivery also introduces duplicates, loss according to QoS, reconnect races, and interleaving among different effects. Effect IDs, request identities, idempotence, per-effect channel ordering, connection epochs, activation generations, and application-level acknowledgements address these conditions. MQTT Wills provide failure signals; they do not execute cleanup.

The strongest framework guarantee is:

> When a provision is withdrawn, no new activation can acquire it. Existing dependents lose ordinary business authority and clean up through their committed bindings. The plugin reverses its broker-owned effects and issues each recorded service retraction without allowing stale activations to affect their replacements.

### Example

A lamp may declare:

```text
PROVIDES $state/lamp/1/contract
PROVIDES $service/lamp/1/control
PROVIDES $reg/lamp/1/controllers
```

A switch may declare:

```text
REQUIRES $state/lamp/1/contract with read access
REQUIRES $service/lamp/1/control
REQUIRES $reg/lamp/1/controllers with register access
```

The lamp publishes its retained contract, receives control operations, and consumes activation-scoped controller records. The switch reads the contract, publishes opaque control operations, and maintains its plugin-generated controller entry.

If the switch deactivates, the plugin retracts its control effects and deletes its registry entry. If the lamp begins a graceful shutdown, the plugin first prevents new switches from binding, then deactivates existing switches, waits for their retractions and registry removal, and finally permits the lamp to remove its subscriptions.

The lamp defines the physical meaning of control and retraction. The plugin does not choose a default lamp state or simulate the lamp.

### Mapping to the paper

| Paper term | MQTT component model |
|---|---|
| Key | Logical `$state`, `$service`, or `$reg` resource contract |
| Component | Customer MQTT component |
| Fiber | One component activation |
| Coeffect specification | Declared `requires` set and access modes |
| Provision | Declared and installed topic resource |
| Coeffect operation | State access, service apply/retract, or registry registration |
| Revertible effect | Managed operation paired with restore, delete, or retract |
| Target view | Provider activations selectable now |
| Committed view | Provider activations bound to one current activation |
| Confinement | Manifest and activation-based topic authorization |
| Recovery | Dependency-ordered cleanup and inverse execution |

The paper's inverse and commutativity witnesses are runtime contract obligations here. The plugin enforces identities, access, bindings, and ordering. Resource authors define the application semantics that make their opaque operations retractable and commutative.

## Configuration Changes

TBD.

## Backwards Compatibility

TBD.

## Document Changes

TBD.

## Testing Suggestions

TBD.

## Declined Alternatives

TBD.
