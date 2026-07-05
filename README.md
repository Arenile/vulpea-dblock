# vulpea-dblock

> Note: This was entirely written by Claude Fable 5. I had an original protoype for
> something like this I had done and thought improving the performance of
> that could be an interesting thing to try with Fable. That means I
> can't make any guarantees about the quality of or safety of the
> project, though, so naturally use your own discretion. If you want to
> take this idea and make a better version for yourself please do so. I
> only ask that you share it so others can use it to! 

Declarative dynamic blocks for [vulpea](https://github.com/d12frosted/vulpea)
with **reactive, incremental refresh**.

The vulpea database is the publisher, every dynamic block instance in an
open buffer is a subscriber, and only blocks whose query results actually
changed get re-rendered — in small, resumable, idle-time slices. Blocks
whose rendered output is unchanged never touch their buffer, so a
save-on-focus-loss workflow never enters a save → refresh → dirty loop.

```org
#+BEGIN: vulpea :tags (paper toread) :todo t :sort mtime :reverse t :limit 20
- [[id:...][Some paper]]
- [[id:...][Another paper]]
#+END:
```

## Why

The usual approach — refresh every dynamic block in every buffer whenever
anything changes — has three failure modes this package eliminates:

1. **Over-refresh.** A change to one note re-runs every query in every
   block in every buffer. Here, a change event is matched against
   dependency indices (tags, link targets, result membership) and only
   plausibly-affected blocks are marked dirty.
2. **Restart-from-scratch.** If typing interrupts a refresh pass, naive
   implementations restart the whole pass. Here, interrupted work stays
   in the queue and resumes on the next idle slice.
3. **Coarse work units.** The atomic unit is one block (one candidate
   query, at most one buffer edit), not one whole buffer. Budget checks
   (`vulpea-dblock-tick-budget`, default 50 ms) happen between blocks.

Marking a block dirty does **not** mean re-rendering it. The scheduler
first re-runs the candidate query and compares a result signature
(ordered id/title/todo/priority/mtime tuples). Unchanged → done, no
render, no buffer touch. Changed → render to a string and byte-compare
against the current block body; only a real difference causes a buffer
edit. False positives from coarse matching are therefore nearly free.

## Setup

```elisp
(add-to-list 'load-path "/path/to/vulpea-dblock")
(require 'vulpea-dblock)
(vulpea-dblock-mode 1)
```

`vulpea-dblock-mode` is a global minor mode. It advises
`vulpea-db-update-file` (the choke point all vulpea sync paths go
through: file watchers, full scans, `vulpea-create`) and
`vulpea-db--delete-file-notes` (deletions), scans already-open org
buffers, and registers blocks in any org file you open under
`vulpea-db-sync-directories`. External edits (git pull, Syncthing) are
covered because vulpea's watchers feed the same path. Disabling the mode
removes all advice, hooks, and timers and clears the registry.

## Block parameters

| param           | value                            | meaning                                                                 |
|-----------------|----------------------------------|-------------------------------------------------------------------------|
| `:tags`         | list of symbols/strings          | notes having **all** of these tags                                       |
| `:tags-any`     | list                             | notes having **any** of these tags                                       |
| `:backlinks-to` | id string, title/alias, or `self`| notes linking **to** the given note (`self` = note containing the block) |
| `:links-from`   | id string, title/alias, or `self`| notes linked **from** the given note                                     |
| `:todo`         | `t`, keyword string, or list     | `t`: any todo state; string/list: only those states                      |
| `:exclude-done` | `t`                              | drop notes in the `DONE` state                                           |
| `:filter`       | function symbol                  | final predicate `(fn NOTE) -> bool`                                      |
| `:sort`         | `title` \| `mtime` \| fn symbol  | sort key (default `title`); fn gets a note, returns a key                |
| `:reverse`      | `t`                              | reverse the sort                                                         |
| `:limit`        | integer                          | cap result count                                                         |
| `:format`       | format string or fn symbol       | default `"- [[id:%i][%t]]"`; fn gets a note, returns a line              |
| `:empty`        | string                           | text when no results (default `/none/`)                                  |

Format string specs: `%i` id, `%t` title, `%o` todo state, `%p`
priority, `%%` literal percent.

Additional keys preserved from the legacy writer and accepted on both
block types: `:priority "A"`, `:file "substring"`, `:todo-only t`, and
the sort keys `todo` / `priority`. `self` resolves to the ID property of
the nearest enclosing heading, falling back to the file-level ID.

Candidate selection always uses vulpea's indexed queries
(`vulpea-db-query-by-tags-every`, `-by-tags-some`, `-by-links-some`,
`-by-ids`) when an indexable param is present; a full `vulpea-db-query`
runs only for blocks with none. All other constraints are post-filters.

## Commands

| command                        | what it does                                                         |
|--------------------------------|----------------------------------------------------------------------|
| `vulpea-dblock-refresh`        | synchronously refresh the block at point (bind it to your refresh key) |
| `vulpea-dblock-refresh-buffer` | synchronously refresh every block in the buffer                       |
| `vulpea-dblock-refresh-all`    | mark all registered blocks dirty and drain the queue                  |
| `vulpea-dblock-migrate-buffer` | rewrite `#+BEGIN: node-list` headers to `#+BEGIN: vulpea` in place    |
| `vulpea-dblock-report`         | per-block last query/render durations — find pathologically slow blocks |

`C-c C-x C-u` (`org-dblock-update`) and `org-update-all-dblocks` also
keep working, since both block types are registered as ordinary org
dynamic block writers. Only the package's own refresh paths get the
byte-diff "never dirty an unchanged buffer" guarantee, though.

## Legacy `node-list` blocks

Existing `#+BEGIN: node-list` blocks keep working unchanged through a
thin alias with the old writer's exact semantics: `:tag`, `:tags` +
`:tags-match`, `:backlinks-to`/`:links-from` by id, title or alias,
`:todo`, `:exclude-done`, `:todo-only`, `:priority`, `:file`,
`:order-by`, `:limit`, `:empty-message`, and `:format` functions called
as `(FN TITLE ID TODO PRIORITY)` — byte-identical default output
included. They participate in reactive refresh like `vulpea` blocks.

`M-x vulpea-dblock-migrate-buffer` rewrites headers to the new syntax
(translating param names). Blocks with a custom `:format` function are
skipped, because legacy formatters have a different calling convention;
they simply stay `node-list` blocks.

### Converting a custom `:format` function

Custom formats are fully supported on `vulpea` blocks — the function
just receives the whole `vulpea-note` instead of four positional
arguments, which gives it access to strictly more data (tags, path,
aliases, meta, timestamps, …):

```elisp
;; Legacy node-list convention: (FN TITLE ID TODO PRIORITY) -> line
(defun my/paper-line (title id todo _priority)
  (format "- %s[[id:%s][%s]]\n" (if todo (concat todo " ") "") id title))

;; New vulpea convention: (FN NOTE) -> line
(defun my/paper-line (note)
  (format "- %s[[id:%s][%s]]"
          (if-let ((todo (vulpea-note-todo note))) (concat todo " ") "")
          (vulpea-note-id note)
          (vulpea-note-title note)))
```

Trailing newlines are optional under the new convention (lines are
joined for you). After rewriting the function, rename the block header
from `node-list` to `vulpea` by hand (or re-run
`vulpea-dblock-migrate-buffer` after removing `:format`, then add it
back).

## Tuning

| variable                        | default | meaning                                        |
|---------------------------------|---------|------------------------------------------------|
| `vulpea-dblock-idle-delay`      | `0.5`   | debounce between a db change and the first slice |
| `vulpea-dblock-tick-budget`     | `0.05`  | seconds of work per slice                        |
| `vulpea-dblock-tick-gap`        | `0.1`   | idle re-arm between slices                       |
| `vulpea-dblock-storm-threshold` | `100`   | events per debounce window before mark-all-dirty |
| `vulpea-dblock-default-format`  | `"- [[id:%i][%t]]"` | default line format for `vulpea` blocks |

During a full db scan (`vulpea-db-sync-full-scan`) the per-file events
would exceed the storm threshold; the scheduler then collapses the storm
into a single re-verification of every block, and the publisher stops
capturing per-file old/new state until the window resets.

## Development

```sh
make test      # ert suite: unit + integration (temp vulpea db)
make compile   # byte-compile with warnings-as-errors
```

Tests locate vulpea through `package-initialize`, so run them on a
machine where vulpea is installed. Integration tests build a scratch
database in a temp directory and drive the scheduler synchronously; they
skip themselves if the database backend is unavailable.

### Design notes

- **Result signatures include title/todo/priority, not just mtime.**
  vulpea stores note mtimes at one-second granularity
  (`"%Y-%m-%d %H:%M:%S"`), so `(id . mtime)` pairs would miss a retitle
  landing in the same second as the previous sync. The rendered fields
  are carried explicitly; mtime remains as a catch-all for custom
  `:format` functions reading other note fields.
- **Deletions are their own event source.** `vulpea-db-update-file` never
  fires for deleted files; those flow through
  `vulpea-db--delete-file-notes`, which is advised separately (suppressed
  while inside an update, which deletes-then-reinserts internally).
- **Membership index.** Besides tag/target indices, every block records
  which files its last result came from. A change to any of those files
  dirties the block, which catches "note left the result set" and
  member-note edits (e.g. a retitle changing only a link description in a
  `:links-from` block) that no dependency key could see.
- An unresolvable link target (missing note, no `self` ID) degrades the
  block to "verify on every event" rather than erroring — correctness
  never depends on precise matching, only efficiency does.

## License

GPL-3.0-or-later, like vulpea itself. See [LICENSE](LICENSE).
