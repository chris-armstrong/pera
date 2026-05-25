# Eio Concurrency Guidelines

This document covers correct usage of [Eio](https://github.com/ocaml-multicore/eio)
in Pera. These rules exist because Eio's scheduling semantics differ subtly from
typical async runtimes, and the gaps cause hard-to-reproduce deadlocks.

---

## 1. Fork scheduling is head-of-queue

`Eio.Fiber.fork ~sw f` does **not** run `f` in the background and then continue
the current fibre. The forked fibre is placed at the **head** of the run queue and
runs first. The continuation of the current fibre only executes after the forked
fibre yields or completes.

### Implications

- If you fork a producer and then immediately call `Eio.Condition.await`, the
  producer may have already broadcast before you are waiting → missed signal →
  deadlock. Use `Eio.Promise` instead (see §2).
- If you fork a producer that pushes events and closes a stream, the consumer
  must be ready to drain the stream before the fork, or buffer events.
- Cancellation cleanup (forked inside an exception handler) runs before the
  cancelling code resumes.

---

## 2. Promise vs Condition for one-shot signals

**Always use `Eio.Promise` for one-shot completion signals.**

`Eio.Condition` signals are **not sticky** — a `broadcast` or `signal` is lost if
no fibre is waiting at the exact moment it fires. Because forks run head-of-queue,
the signalling fibre often completes *before* the waiting fibre is scheduled. The
broadcast fires with nobody listening, and the waiter then blocks forever.

`Eio.Promise.resolve` is **sticky** — once resolved, any future `await` on it
returns immediately regardless of scheduling order.

### Bad — Condition for one-shot sync
```ocaml
let started = Eio.Condition.create () in
Eio.Fiber.fork ~sw (fun () ->
  Eio.Condition.broadcast started;   (* fires before waiter is scheduled *)
  do_work ());
Eio.Condition.await_no_mutex started (* may block forever *)
```

### Good — Promise for one-shot sync
```ocaml
let started, resolve_started = Eio.Promise.create () in
Eio.Fiber.fork ~sw (fun () ->
  Eio.Promise.resolve resolve_started ();  (* sticky; safe *)
  do_work ());
Eio.Promise.await started  (* returns immediately even if already resolved *)
```

Use `Eio.Condition` only for **multi-waiter, reusable** notifications where:
- Multiple fibres wait on a shared predicate (e.g. a queue becoming non-empty), AND
- The waiting fibre re-checks the predicate in a loop after waking.

---

## 3. Stream cancellation and explicit cleanup

`Eio.Stream.take` is cancellation-aware. When a switch is cancelled, any fibre
blocked on `take` receives a `Cancelled` exception and unblocks. When a forked
fibre raises an unhandled exception, Eio cancels the **whole switch**, so
consumers under the same switch also get `Cancelled`.

**If producer and consumer share the same switch** (the normal pattern), there is
no deadlock on cancellation — the switch cancellation unblocks the consumer
automatically.

**`Event_stream` does not currently take a `~sw` parameter** and does not
auto-close when a switch ends (unlike `Eio.Buf_write.create ?sw` which calls
`abort` via `Switch.on_release`). Adding a `~sw` parameter is a planned
improvement, but blocked by the fact that `Event_stream.close_error` must call
`Eio.Stream.add` to push the sentinel — which blocks if the stream is full and
there is no active consumer.

**Explicit `close_error` in the exception handler is only needed when:**
- The consumer runs under a **different** switch than the producer, OR
- You need to emit a specific final event (e.g. `AE_agent_end`) before the stream
  terminates, OR
- You want a readable error string on the stream rather than a raw `Cancelled`
  exception reaching the consumer.

### Pattern — explicit cleanup when one of the above applies

```ocaml
Eio.Fiber.fork ~sw (fun () ->
  match
    push_all_events stream;
    Event_stream.close stream (Ok result)
  with
  | () -> ()
  | exception exn ->
      (* Emit cleanup event + meaningful error message before stream closes. *)
      (try Event_stream.close_error stream (Printexc.to_string exn)
       with _ -> ()))  (* swallow double-close *)
```

In the agent loop this is used because `AE_agent_end` must always be emitted and
the error should be human-readable — not because the switch topology requires it.

---

## 4. Use `Eio.Cancel.protect` for cleanup after cancellation

When a switch is cancelled, all fibres under it receive a cancellation exception.
Code that must run regardless (emitting a final event, closing a stream with a
meaningful error) must be wrapped in `Eio.Cancel.protect`:

```ocaml
| exception exn ->
    Eio.Cancel.protect (fun () ->
      push_event out_stream (AE_agent_end { messages = !messages_ref });
      Event_stream.close_error out_stream (Printexc.to_string exn))
```

`Eio.Cancel.protect` ensures the body runs to completion even inside a cancelled
context. Use it sparingly — only for genuine cleanup, never to bypass cancellation
for normal work.

---

## 5. Switch semantics

- `Eio.Switch.run f` runs `f sw` and does not return until **all fibres forked
  under `sw` have completed** (normally or via exception).
- Raising inside `Switch.run` cancels all child fibres, then re-raises after they
  finish.
- `Eio.Switch.fail sw exn` cancels children and injects `exn` into the switch
  result.
- Never store a `sw` value and fork fibres under it after `Switch.run` returns —
  the switch is already dead and forking raises.

---

## 6. IO functions take `~sw`, not `~env`

- Every function that does IO takes `sw:Eio.Switch.t` as a labelled argument.
- Cancellation is via `Eio.Cancel.t` or switch cancellation — never via custom
  boolean flags or mutable references.
- Fibres are always children of a switch; never use `Eio.Fiber.fork_daemon`
  unless you have a specific, documented reason.

---

## 7. Choosing the right synchronisation primitive

| Need | Use |
|------|-----|
| One-shot "done" signal | `Eio.Promise` |
| Bounded producer/consumer queue | `Eio.Stream` |
| Mutual exclusion over shared state | `Eio.Mutex` |
| Multi-waiter predicate loop | `Eio.Condition` (with re-check) |
| Backpressure in event pipelines | `Event_stream` (project-internal) |

---

## Checklist

Before submitting concurrent code, verify:

- [ ] One-shot completion signals use `Eio.Promise`, not `Eio.Condition`
- [ ] Every fork that owns a stream closes it in the exception arm
- [ ] Cleanup after cancellation is wrapped in `Eio.Cancel.protect`
- [ ] All fibres are forked under a switch (not detached)
- [ ] `Eio.Switch.run` scopes are as narrow as possible
- [ ] No `Eio.Fiber.fork_daemon` without explicit justification
