# vulpea-dblock — Implementation Plan

A vulpea extension providing declarative dynamic blocks with reactive,
incremental refresh. Replaces the hand-rolled `org-dblock-write:node-list`
+ "refresh every dblock in every buffer on any db change" machinery in
`init.el` with a publisher–subscriber model: the vulpea database is the
publisher, each dynamic block instance is a subscriber, and only blocks
whose results actually changed get re-rendered — in small, resumable,
idle-time slices.

---

## 1. Problem being solved (read this before coding)

The current setup in `init.el` (section "Dynamic block refresh"):

- Advises `vulpea-db-update-file` → debounced idle timer →
  `my/org-dblock-refresh--run` iterates **all** open org buffers and runs
  `org-update-all-dblocks` in each one containing any dblock.
- Three concrete failure modes to eliminate:
  1. **Over-refresh**: a change to one note re-runs every query in every
     block in every buffer, including blocks whose results cannot have
     changed.
  2. **Restart-from-scratch**: if keyboard input arrives mid-pass, the
     pass aborts and reschedules the *whole* thing. Under intermittent
     typing this loops for many cycles before a pass ever completes,
     producing repeated visible hitches.
  3. **Coarse work units**: the unit of interruptibility is "one whole
     buffer" (all its blocks + all their queries), which is too large to
     hide inside a typing pause.

Success criterion: during normal editing with ~50 open note buffers and
~20 blocks, a single note save causes work only in blocks whose result
set changed, each work slice stays under a configurable time budget
(default 50ms), progress is never discarded on interruption, and blocks
whose rendered output is unchanged never dirty their buffer.

## 2. Goals / non-goals

Goals:
- Drop-in replacement for the existing `node-list` block with a cleaner,
  documented param interface.
- Reactive refresh driven by actual db ingestion events (covers external
  edits via Syncthing/git, since vulpea's file watchers feed the same
  path).
- Zero buffer modification when output is unchanged (preserves the
  save-on-focus-loss workflow without save→refresh→dirty loops).
- Refresh-on-open for stale blocks in newly visited files.
- Global minor mode to turn the whole system on/off cleanly.

Non-goals (v1):
- No refresh of blocks in files that aren't open in a buffer (batch/CLI
  regeneration can be a later `vulpea-dblock-update-directory` command).
- No caching layer inside vulpea itself; rely on its indexed queries.
- No org-agenda integration.
- No attempt to patch org's dblock machinery generally; we only own our
  own block type.

## 3. Repository layout

```
vulpea-dblock/
├── vulpea-dblock.el            ; entry point, minor mode, block writer, params DSL
├── vulpea-dblock-registry.el   ; subscription registry + change matching
├── vulpea-dblock-render.el     ; query execution, formatting, diff-write
├── vulpea-dblock-scheduler.el  ; dirty queue, idle-time budgeted draining
└── tests/
    ├── test-registry.el
    ├── test-render.el
    ├── test-scheduler.el
    └── fixtures/               ; small org trees for integration tests
```

Package headers, `lexical-binding: t`, dependencies: `(emacs "29.1")`,
`vulpea` (v2), `org`. Follow vulpea's naming convention: public symbols
`vulpea-dblock-*`, private `vulpea-dblock--*`.

## 4. Block syntax (user-facing)

One generic block type:

```org
#+BEGIN: vulpea :tags (paper toread) :todo t :sort mtime :reverse t :limit 20
... generated ...
#+END:
```

Params (audit `org-dblock-write:node-list` in the current `init.el` and
preserve its exact filtering semantics; the list below is the superset
to support):

| param            | value                          | meaning                                        |
|------------------|--------------------------------|------------------------------------------------|
| `:tags`          | list of symbols/strings        | notes having ALL of these tags                 |
| `:tags-any`      | list                           | notes having ANY of these tags                 |
| `:backlinks-to`  | id string, or `self`           | notes linking TO the given note (`self` = note containing the block) |
| `:links-from`    | id string, or `self`           | notes linked FROM the given note               |
| `:todo`          | `t` or keyword string          | only notes with (that) todo state              |
| `:exclude-done`  | `t`                            | drop notes in done states                      |
| `:filter`        | function symbol                | final predicate `(fn note) -> bool`            |
| `:sort`          | `title` \| `mtime` \| fn symbol| sort key (default `title`)                     |
| `:reverse`       | `t`                            | reverse sort                                   |
| `:limit`         | integer                        | cap result count                               |
| `:format`        | format string or fn symbol     | default `"- [[id:%i][%t]]"`; fn gets a note, returns a line |
| `:empty`         | string                         | text when no results (default `/none/`)        |

Candidate selection must use vulpea's **indexed** queries first
(`vulpea-db-query-by-tags-every`, `-by-tags-some`, `-by-links-some`, …)
and only fall back to full `vulpea-db-query` when no indexed param is
present — same strategy as the existing writer. `self` resolution: the
id of the nearest enclosing heading/file with an ID property.

Back-compat: register `org-dblock-write:node-list` as a thin alias that
translates old param names to the new writer, so existing blocks in the
note collection keep working without a mass rewrite. Also provide
`M-x vulpea-dblock-migrate-buffer` that rewrites `#+BEGIN: node-list`
headers to `#+BEGIN: vulpea` in place.

## 5. Data model

```elisp
(cl-defstruct vulpea-dblock--sub
  id            ; stable key: (buffer . position-marker) identity, gensym ok
  buffer        ; the buffer object
  marker        ; marker at the #+BEGIN line (moves with edits)
  params        ; parsed plist from the block header
  dep-keys      ; dependency descriptor, see §6
  result-hash   ; hash of last query result (ordered list of (id . mtime))
  render-hash   ; hash of last rendered string
  dirty         ; nil | t
  broken)       ; t if marker no longer points at a matching block
```

Registry: a hash table `id -> sub` plus secondary indices for matching
(see §6): `tag -> (list sub)`, `target-id -> (list sub)`, and a list of
"global" subs (no indexable deps). Store subs buffer-locally too
(`vulpea-dblock--buffer-subs`) for O(1) cleanup on `kill-buffer-hook`.

## 6. Publisher side: change events and affected-set matching

**Event source.** `:around` advice on `vulpea-db-update-file` (the
public choke point all sync paths use — watcher queue, full scans,
`vulpea-create`). In the advice:

1. Before calling the original: fetch the note state currently in the db
   for that path — investigate vulpea's API for a by-path query (check
   `vulpea-db-query-by-ids` + a path lookup, or a direct query on the
   notes table; if nothing public exists, run
   `(vulpea-db-query (lambda (n) (string= (vulpea-note-path n) path)))`
   **only if** cheap, otherwise skip old-state capture — see fallback
   below).
2. Call the original.
3. Fetch new state for the path.
4. Build a change event: `(:path PATH :old NOTES :new NOTES)` and pass
   it to `vulpea-dblock--publish`.

**Matching.** For each event, compute the union of tags and link
targets across old+new notes, plus their ids. Mark dirty:

- every sub indexed under any of those tags,
- every sub whose `:backlinks-to` / `:links-from` target id appears in
  the event's ids or link targets,
- every "global" sub (no indexed deps — e.g. blocks using only `:todo`
  or `:filter`).

**Cheap verification before rendering.** Marking dirty does not mean
re-rendering. When the scheduler picks up a dirty sub, it first re-runs
the *candidate query only* and compares `result-hash` (hash over the
ordered `(id . mtime)` pairs after filter/sort/limit). If unchanged →
clear dirty, done, no rendering, no buffer touch. This makes false
positives from coarse matching nearly free and means the fallback "no
old-state available, over-approximate" path is acceptable: correctness
never depends on precise diffing, only efficiency does.

**Fallback if old-state capture is impractical:** match on new state
only and additionally dirty subs whose indexed keys matched this path's
notes at registration time (keep a `path -> subs-that-last-included-it`
reverse map updated on every render). This catches "note left the
result set" cases. Document whichever route is taken.

**Full-scan storms:** during `vulpea-db-sync-full-scan` the advice fires
per file. The scheduler's debounce (§8) must coalesce this into one
verification pass; do not accumulate unbounded per-event garbage.
Detect scans cheaply by queue length and just mark-all-dirty past a
threshold (e.g. >100 events in one debounce window).

## 7. Render pipeline (vulpea-dblock-render.el)

Given a sub:

1. Re-locate the block: verify `marker` still points at a `#+BEGIN:
   vulpea`/`node-list` line whose parsed params equal `sub-params`. If
   not, mark `broken` and trigger a buffer re-scan (§9).
2. Run the query (indexed candidates → filters → sort → limit).
3. Render to a **string** (never straight into the buffer).
4. Compare against the current block body text. If byte-identical →
   update hashes, clear dirty, **do not touch the buffer**.
5. Otherwise replace the block body via a single
   `delete-region`/`insert` inside `org-with-wide-buffer`, preserving
   point if it was inside the block (use `save-excursion` +
   `replace-buffer-contents` on a narrowed region if simpler), and
   preserve the buffer-modified flag when it was previously unmodified
   and the write is a no-op (shouldn't happen given step 4, but keep the
   `buffer-hash` guard as belt-and-braces).
6. Update `result-hash`, `render-hash`, clear dirty.

Never rely on `org-update-all-dblocks`; own the region replacement so
step 4's diff is possible.

## 8. Scheduler (vulpea-dblock-scheduler.el)

State: one FIFO-with-dedup dirty queue (a sub appears at most once), one
pending idle timer, and defcustoms:

```elisp
vulpea-dblock-idle-delay        ; default 0.5  (debounce after publish)
vulpea-dblock-tick-budget       ; default 0.05 (seconds of work per slice)
vulpea-dblock-tick-gap          ; default 0.1  (idle re-arm between slices)
```

Behavior:

- `publish` inserts affected subs into the queue and (re)arms the idle
  timer — it never cancels queued work, only delays the next slice.
- Each tick: process subs from the queue until `tick-budget` elapses or
  `(input-pending-p)`. **Interrupted work stays in the queue** — this is
  the core fix for the restart loop. Re-arm with `run-with-idle-timer`.
- Ordering: subs whose buffer is currently displayed
  (`get-buffer-window-list`) drain first; hidden buffers afterwards.
- A sub whose buffer is dead is dropped; a `broken` sub triggers re-scan
  of its buffer, then is dropped.
- Between individual subs, prefer finishing the current sub over
  aborting it mid-render (a single block render is the atomic unit);
  budget checks happen *between* subs. If a single block's query is
  pathologically slow, that's a query problem, not a scheduler problem —
  but add a `vulpea-dblock-report` command that prints per-sub last
  query/render durations to find such blocks.

## 9. Subscription lifecycle

- **Register:** on `org-mode-hook` (for file buffers under
  `vulpea-db-sync-directories`) and after save, scan the buffer for our
  block headers (`org-dblock-start-re`, filter to our names), diff
  against existing buffer-local subs: add new, update params/markers of
  survivors (param change ⇒ recompute dep-keys, mark dirty), remove
  vanished ones from all indices.
- **Refresh-on-open:** newly registered subs start dirty; the cheap
  verification in §6 means an up-to-date block costs one candidate
  query + hash compare and never dirties a freshly opened buffer. This
  replaces `my/refresh-dblocks-buffer-load`.
- **Unregister:** `kill-buffer-hook` removes the buffer's subs from all
  indices; markers are freed.
- **Manual:** `vulpea-dblock-refresh` (block at point, synchronous,
  bound by the user to `SPC o k`), `vulpea-dblock-refresh-buffer`,
  `vulpea-dblock-refresh-all` (marks everything dirty and drains).
- **Minor mode:** `vulpea-dblock-mode` (global) installs/removes the
  advice, hooks, and cancels timers + clears the registry on disable.
  Enabling must scan already-open org buffers.

## 10. Edge cases checklist (tests must cover these)

- Block deleted while dirty (marker points at unrelated text) → broken →
  rescan, no error, no stray edits.
- Two blocks with identical params in one buffer → two subs, both work.
- Block inside a narrowed region → render must widen.
- Buffer with unsaved user edits → render still allowed, but must not
  clobber the modified flag logic (buffer stays modified).
- `self`-referencing block in a note whose own file just changed.
- Note rename/retitle (link descriptions in rendered output must update:
  title participates in render diff even when the id set is unchanged —
  therefore `result-hash` must include something title/mtime-sensitive;
  using `(id . mtime)` pairs covers this since retitle bumps mtime, but
  add an explicit test).
- File deleted from disk (event with `:new` empty).
- `vulpea-db-sync-full-scan` mid-session → coalesced, no hitch storm.
- Killing Emacs with pending queue → no persistence needed, but no
  errors on shutdown (`kill-emacs-hook` cancels timers).
- Non-file org buffers (e.g. capture buffers) → never registered.

## 11. Testing

- `ert` unit tests per module; registry matching and result-hash logic
  must be pure functions testable without a live db.
- Integration tests: temp dir + real vulpea db (`vulpea-db-location` in
  a temp file), create fixture notes programmatically with
  `vulpea-create`, open buffers with `find-file-noselect`, drive the
  scheduler manually by calling the tick function directly (do not rely
  on real idle timers in tests).
- Perf smoke test: 200 fixture notes, 20 blocks, assert a single-note
  update verifies ≤ the matched subset and performs ≤1 buffer edit.
- Run tests in batch: `emacs -Q --batch -l ert -l tests/... -f
  ert-run-tests-batch-and-exit`.

## 12. Milestones

1. **M1 — render core:** params parsing, query execution, render-to-
   string, diff-write, manual `vulpea-dblock-refresh`. Old `node-list`
   alias. (Usable standalone with no reactivity.)
2. **M2 — registry + lifecycle:** buffer scan/register/unregister,
   refresh-on-open via verification.
3. **M3 — publisher + scheduler:** advice, matching, dirty queue,
   budgeted resumable draining, minor mode. Delete the init.el
   machinery it replaces (`my/org-dblock-*`, find-file refresh) and
   swap in `(vulpea-dblock-mode 1)`.
4. **M4 — polish:** migrate-buffer command, report command, README with
   param table, edge-case tests green.

Each milestone ends with tests passing in batch mode.

## 13. Integration notes for the existing init.el

- Keep: `my/save-on-focus-loss`, the vulpea `use-package` block, agenda
  wiring.
- Delete after M3: `my/org-dblock-refresh-idle-delay`, `--timer`,
  `my/org-buffer-has-dblock-p`, `my/org-dblock-refresh-buffer`,
  `--run`, `my/org-dblock-schedule-refresh`, the
  `vulpea-db-update-file` advice, `my/refresh-dblocks-buffer-load` and
  its `find-file-hook`, and rebind `SPC o k` to
  `vulpea-dblock-refresh`.
- `org-dblock-write:node-list` in init.el is superseded by the alias in
  the package; remove it from init.el once the alias is verified against
  a few real blocks.
