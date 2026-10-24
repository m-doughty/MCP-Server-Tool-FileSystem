[![Actions Status](https://github.com/m-doughty/MCP-Server-Tool-FileSystem/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/MCP-Server-Tool-FileSystem/actions)

MCP::Server::Tool::FileSystem
=============================

A root-confined filesystem toolkit for [MCP::Server](https://github.com/m-doughty/MCP-Server).

Give a model a directory, not a machine. The pack registers eleven tools — `read`, `write`, `edit`, `list`, `glob`, `grep`, `map`, `stat`, `mkdir`, `move` and `delete` — and every path argument they take is interpreted relative to a configured root that no argument can escape.

Synopsis
--------

Plug it into a server you are building by hand:

```raku
use MCP::Server;
use MCP::Server::Tool::FileSystem;

my $server = MCP::Server.new(:name<workspace>, :version<1.0>);

$server.plug: MCP::Server::Tool::FileSystem.new(root => '/srv/notes');
# Registers fs_read, fs_write, fs_edit, fs_list, fs_glob, fs_grep,
# fs_map, fs_stat, fs_mkdir, fs_move, fs_delete

$server.run;   # stdin/stdout
```

Or name it in a one-shot server, with no `use` statement at all — the toolkit is loaded at runtime:

```raku
use MCP::Server;

MCP::Server.new(
    :name<workspace>,
    :tools[
        'FileSystem' => { root => '/srv/notes', prefix => 'notes' },
        'FileSystem' => { root => '/srv/logs', prefix => 'logs', 'read-only' => True },
    ],
).run;
# notes_read, notes_write, ... and logs_read, logs_list, logs_glob,
# logs_grep, logs_map, logs_stat
```

Or skip the Raku entirely and hand `raku-mcp` a config file:

```json
{
  "name": "workspace",
  "version": "1.0",
  "instructions": "Notes are writable; logs are read-only.",
  "tools": {
    "FileSystem#notes": { "root": "/srv/notes", "prefix": "notes" },
    "FileSystem#logs":  { "root": "/srv/logs", "prefix": "logs", "read-only": true }
  }
}
```

```shell
raku-mcp --config=workspace.json

# Or without a file:
raku-mcp --tool='FileSystem={"root":"/srv/notes"}'

# See what a given configuration would register:
raku-mcp --describe='FileSystem={"root":"/srv/notes"}'
```

In a Claude Code `.mcp.json`:

```json
{
  "mcpServers": {
    "notes": {
      "command": "raku-mcp",
      "args": ["--name=notes", "--tool=FileSystem={\"root\":\"/srv/notes\"}"]
    }
  }
}
```

Configuration
-------------

<table class="pod-table">
<thead><tr>
<th>Key</th> <th>Type</th> <th>Default</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>root</td> <td>IO::Path</td> <td>required</td> <td>Directory every path is resolved inside. A plain string is coerced. Must exist and be a directory, or construction dies. Stored resolved.</td> </tr> <tr> <td>read-only</td> <td>Bool</td> <td>False</td> <td>When True, the write, edit, mkdir, move and delete tools are never registered, and stat reports nothing as writable. The six reading tools — read, list, glob, grep, map and stat — are unaffected.</td> </tr>
</tbody>
</table>

`prefix` is reserved by the framework rather than the pack: pass it to `.plug` as `:prefix<...>`, or put it beside the toolkit's settings in a `:tools` entry or config file. Passing it to `.new` or `.from-config` dies. Without one, the pack's own default prefix `fs` applies; an explicit empty prefix registers bare names.

Tools
-----

Names below are unprefixed. With the default prefix they are `fs_read`, `fs_write` and so on.

The headings below are the whole signature, and the published JSON Schema says the same thing: a parameter with no `=` in its heading is in the schema's `required` array, and a parameter shown as `path = '.'` carries that value as its JSON Schema `default`. Both matter more than they look. A schema that marked nothing required would tell a model that `read` may be called with no `path` — and a model that believes it (they do) spends its call on an error instead of an answer. A schema that hid the defaults would leave a model unable to tell `grep` without a `path` (the whole root) from `grep` with one.

### Parameter naming

Parameter names in this pack are a contract, not a matter of taste:

  * Every parameter that names a location is called exactly `path`, or `from` and `to` for the one tool that has two.

  * Multi-word parameters are kebab-case: `old-string`, `new-string`, `replace-all`, `max-results`.

The reason is what sits in front of the server. A permission layer — Claude Code's directory rules, or [MCP::Client::Policy](https://github.com/m-doughty/MCP-Client) — decides whether a call may go through by looking at which files it would touch, and it finds them by name. A tool that called its argument `filename` would sail past a rule written for `path`. If you write a toolkit of your own that is meant to live behind the same guard, use the same names.

### Annotations: which tools may run at once

The six reading tools — `read`, `list`, `glob`, `stat`, `grep` and `map` — declare the MCP annotations `readOnlyHint => True ` and `idempotentHint => True `. The five mutating ones declare nothing.

That is not decoration. A host reads it as a licence to run a batch of those calls **side by side** and to execute identical calls in one batch **once** (`MCP::Server`'s `execute-tool-calls` does exactly that), so it is a claim about the handlers rather than about the intent — and it holds:

  * The observation tools (`read`, `list`, `stat`) take this instance's one mutation lock for the read plus its revision digest, which is the same lock the mutators take.

  * `map` takes the map cache's own lock around the whole map, so two maps of one tree cannot tear the per-file parse cache between them.

  * `glob` touches no instance state at all, and `grep` touches none either — but its scanning phase runs under one **process-wide** lock, so two searches never read files at the same time however many packs there are. That is a VM-level requirement rather than a coherence one, and [How grep searches](#how-grep-searches) says why.

Several reads on **one** pack instance therefore see coherent state. What the annotations do **not** promise is anything about the filesystem underneath: a read running beside another process's write is a race the pack never had a say in, exactly as it always was.

Ordering is untouched by any of this. A host that batches groups only **neighbouring** calls, so a `write` between two `read`s still means read, write, read.

### Structured revisions and conditional mutation

`read`, `list`, `stat` and every successful mutator keep their existing text content and additionally return `structuredContent` with `revisionScheme = sha256-v1`. Each location is `absent`, `file`, `directory`, or `symlink` with an opaque token. File tokens hash exact bytes; directory tokens hash a canonical, path-sorted recursive tree description, so a descendant change changes the directory revision.

The five mutators accept a reserved `_expected-revisions` object keyed by `path`, or `from`/`to` for `move`. It is deliberately absent from the advertised schema: an orchestration layer adds it after the model creates the call. When present, every mutation location needs a token. Comparison and the mutation run under one toolkit mutation lock; a mismatch is an `isError` and does nothing. Calls without the reserved argument retain standalone behaviour.

### read(path, offset?, limit?)

Slurps a UTF-8 text file. Errors if the path is missing, is a directory, or is not decodable text.

    { "name": "fs_read", "arguments": { "path": "notes/todo.md" } }
    => "- buy milk\n- feed the yak\n"

With neither `offset` nor `limit`, what comes back is the file and nothing else: no numbering, no footer, no line-ending translation. That matters — the text is exactly what `edit` will be matching against later.

Pass `offset` (1-based) and/or `limit` to read a window of a long file instead. Ranged output is a *view*: each line is prefixed with its number and a tab, and a footer says where the window sits.

    { "name": "fs_read", "arguments": { "path": "log.txt", "offset": 40, "limit": 3 } }
    => "40\tconnecting
        41\thandshake ok
        42\tsending 12 frames

        [lines 40-42 of 900 total]"

Strip the number and the tab before handing any of that text to `edit` as its `old-string` — the prefixes are not in the file. Windowed lines are split on line endings and rejoined with `\n`, so a CRLF file's `\r`s are not in the windowed output either: before building an `old-string` for a CRLF file, read it without `offset`/`limit` — the unranged form is byte-faithful.

Reading past the end is an answer rather than an error, because that is how a model finds out where the end is:

    { "name": "fs_read", "arguments": { "path": "log.txt", "offset": 5000 } }
    => "'log.txt' has 900 lines; offset 5000 is past the end"

An `offset` or `limit` below 1 *is* an error, as is a non-numeric one. A JSON `true` is refused rather than read as the number 1, which Raku's type system would otherwise let happen quietly.

### write(path, content)

Writes UTF-8 text, replacing any existing contents, and confirms with a byte count. The parent directory must already exist — this tool never creates directories implicitly, so a typo in a path cannot quietly scatter new directory trees. Not registered when `read-only` is set.

    { "name": "fs_write", "arguments": { "path": "notes/todo.md", "content": "- done\n" } }
    => "Wrote 7 bytes to 'notes/todo.md'"

    { "name": "fs_write", "arguments": { "path": "new/todo.md", "content": "x" } }
    => isError: "Parent directory of 'new/todo.md' does not exist; create it with the mkdir tool first"

### edit(path, old-string, new-string, replace-all = false)

Replaces one exact run of text and leaves the rest of the file byte for byte as it was. There is no fuzzy matching and no diff format to get wrong: `old-string` either appears in the file exactly — whitespace, indentation and line endings included — or the call is an error. Not registered when `read-only` is set.

    { "name": "fs_edit", "arguments": {
        "path": "src/app.raku",
        "old-string": "my $port = 8080;",
        "new-string": "my $port = %*ENV<PORT> // 8080;" } }
    => "Replaced 1 occurrence in 'src/app.raku'; wrote 412 bytes"

The uniqueness rule is the whole safety story, so it is strict:

  * **Zero matches** is an error. Read the file first; the text you quote must be what is actually there.

  * **More than one match** is an error too, and the message says how many. Quote more of the surrounding lines until the match is unique, or set `replace-all` to true and mean it.

  * An empty `old-string` is refused: it is a position, not a match.

  * An `old-string` equal to `new-string` is refused: it would report success for having done nothing.

    { "name": "fs_edit", "arguments": {
        "path": "src/app.raku", "old-string": "$port", "new-string": "$listen-port" } }
    => isError: "Found 6 occurrences of 'old-string' in 'src/app.raku'; quote more of
       the surrounding text to pick one out, or set replace-all to true"

    { "name": "fs_edit", "arguments": {
        "path": "src/app.raku", "old-string": "$port", "new-string": "$listen-port",
        "replace-all": true } }
    => "Replaced 6 occurrences in 'src/app.raku'; wrote 431 bytes"

An empty `new-string` deletes the match. Line endings elsewhere in the file are never touched — see [Security](#security) for why that takes deliberate effort in Raku.

### list(path = '.')

One entry per line, sorted, directories marked with a trailing `/` on every platform. An empty directory answers `(empty directory)` rather than an empty string.

    { "name": "fs_list", "arguments": { "path": "notes" } }
    => "archive/\nideas.md\ntodo.md"

### glob(pattern, path = '.')

Walks everything below `path` and returns matching paths *relative to the root*, sorted, one per line.

  * `*` matches any run of characters **within one path segment**.

  * `?` matches exactly one such character.

  * Everything else is literal, and matching is case-sensitive.

  * A pattern with no separator is matched against entry names at any depth; a pattern containing `/` is matched against the path relative to the searched directory.

  * Regexes are not accepted — `.*` means "a literal dot followed by anything", nothing more.

  * Symlinked directories are never descended into, so a glob cannot loop forever or report a file that lives outside the root.

    { "name": "fs_glob", "arguments": { "pattern": "*.md" } }
    => "notes/ideas.md\nnotes/todo.md"

    { "name": "fs_glob", "arguments": { "pattern": "notes/*.md" } }
    => "notes/ideas.md\nnotes/todo.md"      # one segment deep only

    { "name": "fs_glob", "arguments": { "pattern": "*.zzz" } }
    => "No matches for '*.zzz' under '.'"

### grep(pattern, path = '.', regex = false, glob?, context = 0, max-results = 50)

Searches the files below `path` — or `path` itself, if it names a file — and reports matching lines in GNU grep's format, `path:line:text`, with paths relative to the root.

    { "name": "fs_grep", "arguments": { "pattern": "TODO", "path": "src" } }
    => "src/app.raku:14:# TODO: retries
        src/lib/db.raku:203:# TODO: index this"

By default the pattern is **literal text**: no escaping, no surprises, `.` is a full stop. Set `regex` to true and it becomes a **Raku regex, not a PCRE one**. Classes, quantifiers, alternation, anchors and captures read the same; what differs is worth knowing before reaching for it:

  * Whitespace in the pattern is insignificant. `foo bar` matches `foobar`; write `foo ' ' bar` or `foo \s bar` for a literal space.

  * `\d`, `\w`, `\s` and `.` work; `[abc]` is *not* a character class in Raku — that is `<[abc]>`, and `[...]` is a non-capturing group.

  * A pattern containing `{ }` is refused outright rather than run. See [Security](#security).

  * An unparseable pattern is reported as an error before any file is opened, not halfway through the tree.

    { "name": "fs_grep", "arguments": { "pattern": "^ sub \\w+", "regex": true, "glob": "*.rakumod" } }
    => "lib/Thing.rakumod:12:sub parse-header(...)
        lib/Thing.rakumod:44:sub emit(...)"

    { "name": "fs_grep", "arguments": { "pattern": "a(b", "regex": true } }
    => isError: "Invalid regex pattern 'a(b': Unable to parse expression ..."

The rest of the parameters bound what comes back:

  * `glob` filters by **file name only**, using the same matcher as the glob tool, at any depth. A `/` in it is refused — filter names with `glob`, choose where to look with `path`.

  * `context` (0 to 20) shows surrounding lines, marked with `-` instead of `:` so they cannot be mistaken for matches, and separates non-adjacent groups with `--`.

  * `max-results` (1 to 1000, default 50) stops the search after that many *matching* lines and says so. Files are visited in sorted order, so a truncated result is the same result every time.

  * Files that are not UTF-8 text — a NUL byte in the first 8KB, or bytes that will not decode — are skipped in silence. Nothing counts them; [How grep searches](#how-grep-searches) says why that notice was removed.

    { "name": "fs_grep", "arguments": { "pattern": "yak", "context": 1 } }
    => "notes/todo.md-3-shopping:
        notes/todo.md:4:- feed the yak
        notes/todo.md-5-- water the yak
        --
        notes/todo.md-11-later:
        notes/todo.md:12:- rename the yak"

    { "name": "fs_grep", "arguments": { "pattern": "the", "max-results": 2 } }
    => "notes/ideas.md:1:the first
        notes/ideas.md:7:the second

        [stopped at 2 matching lines; raise max-results to see more]"

`grep` is a reading tool: it is registered even when `read-only` is set. *How* it searches — and why it would rather have ripgrep pick the files it opens — is [How grep searches](#how-grep-searches), below.

### How grep searches

`grep` runs its own scan over its own walk and formats every byte of its own answer. What it will hand to an outside tool — and only when there is one — is the question *which files are worth opening at all*:

  * **ripgrep**, if `rg` is on the PATH.

  * **a system `grep`**, if that is there and `rg` is not.

  * **nothing**, on a host with neither (a stock Windows, most minimal containers). The scan then opens every file below the path, exactly as this pack always did.

The three tiers return **the same bytes**. They have to: the external tool never produces a line of the answer, never decides the order, and never sees the `glob`, the `context` or the `max-results`. It answers one question, its answer is used as a **filter** over the ordinary walk, and everything the model reads is then produced by the same scanner it always was. `t/07-grep-parity.rakutest` runs every query through every tier installed on the machine and compares the results as strings.

#### Why

A recursive Raku scan — walk, slurp, decode, split, search — is the heaviest thing in this pack by allocation volume, and several at once reliably tripped a garbage-collector fault in MoarVM 2026.07 that killed the whole process:

```text
MoarVM panic: Heap corruption detected: pointer 0x... to past fromspace
```

Nothing at the Raku level can catch that — the VM prints one line and calls `exit()`, so no `END` block, no `LEAVE`, no signal handler runs. It is a VM bug rather than this pack's, but a search tool that takes the server down when a model asks two questions at once is this pack's problem. Two measures fixed it at six concurrent searches, and both are in:

  * The scanning phase runs under **one process-wide lock**. Process-wide and not per-instance, because the fault is in the collector and does not care how many toolkits there are.

  * When an external searcher is available, the scan only opens the files it named — usually a handful instead of a tree — so the allocation the collector was choking on never happens. The call to the searcher is made **outside** the lock, so those still run in parallel.

#### What is asked, exactly

```shell
rg --files-with-matches --no-config --no-ignore --hidden --no-follow \
   --no-messages --text --fixed-strings -- <pattern> <absolute directory>

grep -r -l -F -a -s -- <pattern> <absolute directory>
```

Every flag is there to make the searcher's idea of "worth opening" a **superset** of the scan's. `--no-ignore` because a `.gitignore` is not this pack's filter (the root is); `--hidden` because the walk does not skip dotfiles; `--no-follow` because it does not descend symlinked directories; `--text` and `-a` because a binary file must still be listed — dropping it is the **scan's** decision, taken on the same NUL sniff as always; `--no-config` because a user's `rg` configuration file must not be able to change what a tool call returns. The searcher runs with `LC_ALL=C` and without `GREP_OPTIONS`, `GREP_COLORS` or `RIPGREP_CONFIG_PATH`.

The `glob` parameter is deliberately **not** passed on: its dialect is this pack's, not ripgrep's, and the scan applies it. Neither searcher's own file list is used for paths or for order, either — their idea of sorted (`a/b` before `a.txt`) is not the walk's (`a` before `a.txt`, then descend).

Two kinds of file are opened whatever the searcher said about them, because its silence cannot mean anything: a **symlink** (no searcher follows one it meets during a traversal, while this pack reads one whose target is inside the root) and a name carrying a **line break** (which cannot be found in a list that arrives one path per line).

#### What never leaves Raku

  * A **regex** search. The pattern is a *Raku* regex, and it is only safe because Rakudo refuses to interpolate one containing a code block — see [Regex interpolation](#regex-interpolation). Ripgrep would read it as Rust regex syntax and a system grep as POSIX: silently, and with different matches.

  * A pattern that is not **printable ASCII**. Raku decodes a file to NFG text before searching it, so a composed `é` in the pattern matches a decomposed one in the file; a byte-oriented searcher would not, and the tiers would disagree.

  * A search of a single **file** rather than a directory. There is one candidate and choosing it externally would be pure overhead.

#### The probe, and how long it is remembered

A searcher counts as usable only once it has actually run and answered `--version`. That costs a process spawn, so the verdict is taken **once per binary per process** and never revisited — the "no" as firmly as the "yes", since paying a failed spawn on every search would cost more than the tier saves. "No" means the binary is not there, or that it ran and gave no version: exited non-zero, or printed nothing. A probe that gets **no answer at all** is not a verdict, and is not kept: a binary that is there but could not be launched — the server out of file descriptors, the system out of processes, the binary being rewritten by an upgrade — or one killed by a signal before it replied is asked again on the next call. A searcher that passed its probe and later cannot be launched is looked for the same way: if its binary has gone, it is dropped there and then, as if its probe had said no, and the searches after it spawn nothing; if it is still there, the failure is the moment's, the next search tries again, and it is not held against the searcher.

#### Which answers are believed

After the probe, each search decides whether **its own** answer can be believed. One that cannot costs that search a full scan and not the tier — until a searcher has given **five** in a row with no believed answer between them, which drops it as a failed probe would. One bad answer is as likely to be the moment (an OOM-killed child, an unlucky list) as the tool, and giving a searcher up over it would leave a long-running server slow for the rest of its life; five in a row is the tool, and hundreds of searches should not each pay a spawn and a scan for it. A believed answer starts the count again, and a launch that failed while the binary was there never counts. An answer is believed when the searcher was not killed by a signal and exited with a status its documentation calls an answer. ripgrep's man page gives 0 for a match, 1 for none and 2 for an error; GNU grep's gives the same three; BSD grep's and POSIX's give 0, 1, and anything above 1 for an error. So:

  * **0 or 1** is an answer.

  * **2 with nothing on stderr** is an answer too. This pack runs every searcher with `--no-messages` or `-s`, which silence exactly the complaints about files it could not open or read, and all three tools still exit 2 for one; a root holding a single unreadable file would otherwise cost every search a full scan. The list such a run prints names every file the tool could read, and the scan cannot read the rest either, so it is the list a clean run would have printed.

  * **2 with a message** is a refusal — an option it does not know, memory exhausted — and is not believed.

  * **Anything else** is not believed: any other status, a child killed by a signal (which Rakudo reports as exit code 0, with the list cut short wherever the signal landed), a launch that never happened, output that is not a list of absolute paths.

Measured on ripgrep 14.1.1, GNU grep 3.12 and BSD grep 2.6.0: an unreadable file or directory exits 2 with every readable match listed and stderr empty, and an unknown option exits 2 with nothing listed and a message on stderr.

The consequence worth stating plainly: installing `rg` while a server is running does not speed up that server, only the next one — unless whatever hosts the pack calls `reset-searchers`, below.

#### Overriding it

<table class="pod-table">
<thead><tr>
<th>Variable</th> <th>Value</th> <th>Effect</th>
</tr></thead>
<tbody>
<tr> <td>MCP_FS_GREP_BACKEND</td> <td>auto (default)</td> <td>ripgrep if it is there, else a system grep, else the Raku scan</td> </tr> <tr> <td>MCP_FS_GREP_BACKEND</td> <td>ripgrep</td> <td>only ripgrep; the Raku scan when it is unusable</td> </tr> <tr> <td>MCP_FS_GREP_BACKEND</td> <td>grep</td> <td>only a system grep; the Raku scan when it is unusable</td> </tr> <tr> <td>MCP_FS_GREP_BACKEND</td> <td>raku</td> <td>never shell out</td> </tr> <tr> <td>MCP_FS_GREP_RG_BINARY</td> <td>a binary name or path</td> <td>what the ripgrep tier spawns; defaults to rg</td> </tr> <tr> <td>MCP_FS_GREP_GREP_BINARY</td> <td>a binary name or path</td> <td>what the grep tier spawns; defaults to grep</td> </tr>
</tbody>
</table>

Any other value of MCP_FS_GREP_BACKEND is an error on the call rather than a silent fallback, so a typo cannot quietly cost a tier.

They exist for the parity tests, which have to pin a search to a tier they choose, and they are read on every call rather than cached. The binary overrides must name the real tool: a searcher that runs happily and prints something **else** cannot be detected, only believed.

#### Re-checking the searchers

Everything the pack learns about the searchers — every probe verdict, the "yes" and the "no" alike, every searcher dropped, every count of answers that could not be believed — lasts for the life of the process. `MCP::Server::Tool::FileSystem::reset-searchers()` forgets all of it, so the next search probes again from scratch: a ripgrep installed since the first search is found, and a searcher dropped in error is given its chance back.

```raku
our sub reset-searchers(--> Nil)
```

It is a library function rather than a tool, because whether the host's programs have changed is the host's question, not the model's. It is process-wide, like the state it clears, which every pack instance in the process shares. It is safe to call while searches are running — a search already under way finishes on what it had — and safe to call again, since clearing nothing changes nothing. It leaves `MCP_FS_GREP_BACKEND` alone; that is read on every search anyway.

A harness that serves the pack to a user is the natural caller: bind it to a command, so the user can say "I have just installed ripgrep" without restarting anything.

```raku
use MCP::Server::Tool::FileSystem;

# One entry in a harness's own command table.
my %commands = rescan => {
    MCP::Server::Tool::FileSystem::reset-searchers();
    'The next search looks for ripgrep and a system grep again.';
};

# ...and when the user types /rescan:
say %commands<rescan>();
```

#### The notice that is gone

`grep` used to end an answer that had skipped unreadable files with

```text
[skipped 2 files that are not UTF-8 text]
```

That line has been **removed**. Ripgrep passes a binary file over in silence and cannot be made to count them, so the notice was the one part of the output that could not survive the question "which tier served this call?". Identical answers are worth more than the count was. The other notice — `[stopped at N matching lines; raise max-results to see more]` — is unchanged: every tier reproduces it, because every tier counts the same matched lines.

### map(path = '.', query?, focus?, max-chars = 8192)

Returns a ranked skeleton of the code below `path`: the files that matter, each as its path followed by the **definition lines** of its most-referenced symbols. Bodies never appear. It is the tool to reach for before reading anything, and it is the reason not to read twenty files to find the two that matter.

    { "name": "fs_map", "arguments": { "path": "src" } }
    => "src/hub.py:
          12: def frobnicate(value):
        ⋮
          48: class Dispatcher:

        src/cli.py:
           7: def main(argv):

        [mapped 2 files (1 skipped: unsupported/binary/too-large), 3 definitions; ranked by references]"

Line numbers are 1-based and pair with `read`'s `offset`, so a definition worth reading is one call away. A `⋮` marks a gap between printed lines, so nothing reads as adjacent that is not.

Ranking is a personalized PageRank over the graph "file A refers to something file B defines". A file is important because the rest of the tree leans on it — not because it is large, and not because it sorts early. Two parameters steer the walk:

  * `query` is space- or comma-separated words. A file whose path or whose defined identifiers contain one of them is weighted ten times, so `query="tokenizer"` re-centres the whole map on the tokenizer's neighbourhood rather than merely grepping for the word.

  * `focus` is space- or comma-separated paths relative to the root, naming files or directories. Each is weighted fifty times: this is "map what is around *this*", for when you already know where you are.

*Which* definitions of a chosen file get printed is a second, separate question, and the answer is not simply "the most referenced". A name's references are shared among the files that define it, and a name that most of the map refers to is set aside altogether. Both rules exist because references are matched by name and nothing else: in a 131-file application, `new` was declared three times and called twelve hundred times, so a naive count made `method new` the one line printed for three unrelated files. Under these rules each of those files is represented by its own class declaration instead, while a symbol that only a handful of files mention — which is what a symbol worth reading looks like — keeps its full weight.

`max-chars` (512 to 65536, default 8192) bounds the answer. The budget is spent **whole files at a time**: when the map does not fit, every file loses its least-referenced definitions first, and whatever still does not fit is dropped as a block rather than cut off mid-file. A half-printed file would invite exactly the mistake the tool exists to prevent — reading a signature that is not really there. The summary line is always last and always present, and says what was left out.

Languages, and how they are read:

  * C, C++, Go, Java, JavaScript, Python, Rust, TypeScript and TSX are parsed with [TreeSitter::Native](https://github.com/m-doughty/TreeSitter-Native), using each grammar's own `tags.scm`. C, C++ and TypeScript get supplemental queries this pack ships, because the vendored ones tag no call references at all (C, C++) or only signature declarations (TypeScript, TSX).

  * Raku — for which no tree-sitter grammar exists — is read by a heuristic scanner: `sub`, `method`, `submethod`, `class`, `role`, `grammar`, `module`, `package`, `token`, `rule`, `regex`, `constant` and `enum` declarations, with comments, Pod blocks and declarator documentation skipped — including the bracketed `#|( … )` and `#=( … )` forms, whose continuation lines carry no `#` and are therefore prose that reads exactly like code. `use Foo::Bar` is an edge to the file that **is** `Foo::Bar`, resolved through a `lib/Foo/Bar.rakumod` index.

  * Everything else is skipped and counted, as are files over 1MB, files that are not text, and unreadable ones.

`.git`, `node_modules`, `target`, `build`, `dist`, `vendor`, `__pycache__`, virtualenvs and every dot-directory are never descended into: a vendored copy of a library outranks the code that uses it, which makes for a confident and useless map. The walk stops after 5000 files and says so.

Parse results are cached per file, keyed on modification time and size, for the lifetime of the toolkit instance — so mapping, editing one file and mapping again re-reads exactly that file. The cache is not bounded and is not written to disk.

`map` is a reading tool: it is registered even when `read-only` is set.

### stat(path)

    { "name": "fs_stat", "arguments": { "path": "notes/todo.md" } }
    => "path: notes/todo.md
        type: file
        size: 26
        modified: 2026-07-29T20:14:02Z
        symlink: no
        readable: yes
        writable: yes"

`type` is `file`, `directory` or `other`; `modified` is ISO 8601 in UTC; `writable` is always `no` on a `read-only` pack, whatever the mode bits say, because no tool in that configuration can write.

### mkdir(path)

Creates a directory and any missing parents. Creating one that already exists is a no-op, not an error, so a model retrying itself does not get punished. Not registered when `read-only` is set.

    { "name": "fs_mkdir", "arguments": { "path": "notes/archive/2026" } }
    => "Created directory 'notes/archive/2026'"

### move(from, to)

Renames a file or directory, or moves it somewhere else inside the root. Both `from` and `to` go through the same containment checks, so neither end can leave the sandbox. A directory moves with everything inside it. Not registered when `read-only` is set.

    { "name": "fs_move", "arguments": { "from": "notes/todo.md", "to": "notes/archive/todo.md" } }
    => "Moved 'notes/todo.md' to 'notes/archive/todo.md'"

Nothing is ever overwritten and nothing is created implicitly:

  * An existing `to` — file or directory — is an error. Delete it first if that is really what you meant.

  * A `to` whose parent directory does not exist is an error, exactly as with `write`. Use `mkdir` first.

  * Moving the root itself is refused.

There is no copy-and-delete fallback across filesystems: the move is a rename, and a rename that the OS refuses (a `to` on a different mount, say) is reported as the error it is rather than half-performed. See [Security](#security).

### delete(path, recursive = false)

Deletes a file, or a directory that is empty. Not registered when `read-only` is set.

    { "name": "fs_delete", "arguments": { "path": "notes/scratch.md" } }
    => "Deleted file 'notes/scratch.md'"

    { "name": "fs_delete", "arguments": { "path": "notes/empty" } }
    => "Deleted empty directory 'notes/empty'"

    { "name": "fs_delete", "arguments": { "path": "notes/archive" } }
    => isError: "Directory 'notes/archive' is not empty; set recursive to true to
       delete it and everything below it"

`recursive` is `rm -rf` and nothing less: the directory and every file below it go, with no undo and no confirmation step.

    { "name": "fs_delete", "arguments": { "path": "notes/archive", "recursive": true } }
    => "Deleted directory 'notes/archive' and everything below it"

Symlinks are deleted as the links they are, never followed — a recursive delete of a directory containing a link to somewhere else removes the link and leaves its target alone. Deleting the root itself is refused.

Errors
------

Handlers throw; the framework turns that into a tool result with `isError: true` and the message as its text, so the model sees what went wrong and can correct itself. Missing or non-string arguments are reported the same way — the MCP input schema advertises what is required, but nothing in the protocol enforces it.

Security
--------

Confinement is the whole point of this pack, so it is done in layers that each hold on their own. For a path argument `$rel`:

  * **Relative only.** Anything that could be absolute is rejected textually, before any filesystem call: a leading `/` or `\`, a `X:` drive prefix, or a `\\server\share` UNC prefix.

  * **No `..` at all.** `..` segments are refused even when the result would have stayed inside the root (`a/../b` is an error, not a synonym for `b`). One rule is easier to audit than an arithmetic one.

  * **No device names.** Segments Windows resolves to devices regardless of directory — `CON`, `PRN`, `AUX`, `NUL`, `CONIN$`, `CONOUT$`, `COM0`..`COM9`, `LPT0`..`LPT9` and the superscript `COM¹`..`COM³`, `LPT¹`..`LPT³`, with or without an extension and with trailing spaces before it (`NUL .txt` is `NUL`) — are refused on every platform, so behaviour is identical everywhere rather than only safe where it is tested.

  * **On Windows, no name that opens another name.** A segment holding a `:` (`x:stream` is a data stream of `x`, and `link::$INDEX_ALLOCATION` is the directory `link` itself), one ending in a dot or a space (Win32 drops them: `secret.` **is** `secret`), and one shaped like an 8.3 short name (a base of up to eight characters holding a `~` and a letter or digit, at most a three-letter extension: `SECRET~1`, `PROGRA~1.TXT`, a Samba server's `SECRE~A1`) are refused. None of them escapes the root, but each lets the name a permission layer in front of this pack judged differ from the name the OS opens — a rule about `secret` walked past by `SECRET~1`. The file's full name always works. On POSIX all of these are ordinary names.

  * **No null bytes.**

  * **Physical-path symlink chase.** The candidate path is built segment by segment under the root; then every symlink in it is chased to its destination — component by component, the way `realpath` works, with a hop budget against cycles — and the *physical* result is checked against the root. A symlink planted inside the sandbox therefore cannot be used as a door out of it, whether it points at a file or a directory, whether directly or through a chain, and whether its target is absolute or relative. The chase is the pack's own (over `readlink`), **not** `IO::Path.resolve`, because `.resolve` does not follow symlinks on Windows — an unfollowed link is an open door the OS walks through at open time even though a check did not. One code path runs on every platform, and it resolves `..` the way *this* platform's OS does: physically on POSIX, by name on Windows (see [Resolving a path the way the OS will](#Resolving a path the way the OS will)). A link whose target cannot be read, a chain that exceeds the hop budget, a Windows drive-relative (`C:foo`) or device-path (`\\?\…`) target, and a Windows segment of dots and spaces other than `.` and `..` are all refused outright: fail closed.

  * **Parent-chain containment, not string prefixes.** The final check walks `.parent` from the chased path up to the filesystem root looking for the root itself. `/srv/root2` is not inside `/srv/root`, and no separator-spelling difference can fake a match — on Windows both slash spellings are unified before comparing.

The textual rejections are deliberately redundant with the physical check: two independent layers fail independently, and they make the failure message say what the model did wrong.

Comparison is exact-case. On a case-insensitive filesystem, a root configured with different casing than the path the OS reports can only produce a *false negative* — access denied — never a false positive. It fails closed.

### Byte fidelity, and why CRLF is a security property

`read` and `edit` never see a decoded-and-re-encoded copy of your file: they read bytes and decode them once, and `edit` writes bytes back.

This is deliberate, and it took work. Raku's `IO::Path.slurp` in text mode silently folds `CRLF` into `LF`, and `.spurt` does not put it back. An `edit` that round-tripped through the text path would therefore rewrite the line endings of every line in the file it did not touch — a one-line change arriving as a whole-file diff. On a CRLF checkout that is not a cosmetic problem: it is an invisible, unreviewable change to code, made by a tool the reviewer trusts to change one line.

So the guarantee is: **`edit` changes the bytes you asked it to change and no others**, and the text `read` hands back is what `edit` will be matching against, byte for byte. The cost is that an `old-string` copied out of a CRLF file must carry its CRLF; the alternative was silent corruption.

### Regex interpolation

`grep`'s `regex` mode interpolates the client's pattern into a real Raku regex (`/<$pattern>/`). That is only safe because Rakudo refuses, by default, to interpolate a pattern containing a code block — a pattern like `{ unlink 'x' }` is rejected with *Prohibited regex interpolation* rather than executed. The refusal comes back to the model as an ordinary tool error.

**Never add `use MONKEY-SEE-NO-EVAL` to this file.** That pragma exists to turn exactly this guard off, and turning it off here converts a search tool into remote code execution. The module carries a comment saying so, and `t/02-tools.rakutest` asserts that an injection pattern comes back as a clean error — that test is the guard on the guard.

Malformed patterns are validated before the walk starts, so a bad pattern costs one clear error rather than a partial traversal.

Residual risks worth knowing:

  * A symlink already inside the root that points *within* the root is followed, by design. If you populate the sandbox from an untrusted source, populate it without symlinks.

  * Windows 8.3 short names (`PROGRA~1`) are not expanded. In a path argument one is refused (see above). In a link target, a short name never matches a root spelt long, or the other way round, so it is refused: a false denial, never an escape. Configure the root the way the OS reports it. A file whose own long name has the short-name shape (`DATA~1.TXT`) cannot be reached by this pack on Windows.

  * Confinement is not a permission system. Anything the server process can read under the root, the model can read, and on a read-write pack anything it can write, the model can `delete`. Run it as a user with no more access than you intend to grant, use `read-only` unless writes are actually wanted, and put a permission layer in front of it if "the whole root" is more than you meant to hand over.

  * `delete` with `recursive` is `rm -rf`, applied to a path the model chose. It refuses the root itself and it unlinks symlinks rather than following them, but within the root it is exactly as final as it sounds. This is the tool to gate behind a permission layer first.

  * `move` is a rename and only a rename. If the root spans a mount point — a bind mount, a network share grafted into the tree — a move across it fails with the OS's own error instead of silently copying and deleting. Honest, but it means such a move is simply not available; do it with `read` and `write` if you must.

  * Conditional revisions are authoritative among calls through one toolkit instance. An unrelated process writing the same filesystem does not take this lock, so it can still race between the toolkit's comparison and operating-system mutation. Its completed changes are detected by the next comparison; it does not participate atomically.

  * Nothing here rate-limits or size-limits: `read` will happily slurp a huge file into memory, `glob` will walk a huge tree, and `grep` walks the whole tree below the path it is given — opening every text file in it when no external searcher is installed, and only the files one named when there is (`max-results` bounds the *output*, not the walking). `map` is the one exception — it prunes, skips files over 1MB, stops after 5000 files and bounds its own output — but its first pass over a large tree still costs a parse of every source file in it. Point the pack at a workspace, not at `/`.

Resolving a path the way the OS will
------------------------------------

The resolver behind containment is public, for any code that has to name a directory where the operating system will check it: a sandbox profile that lists the paths a child may write, a lock keyed on a path, a "which root is this under" test of your own.

```raku
use MCP::Server::Tool::FileSystem;

my &physical = &MCP::Server::Tool::FileSystem::physical-path;

# /srv/current -> releases/42
say physical('/srv/current/notes.txt'.IO);   # "/srv/releases/42/notes.txt".IO

# C:\Users\me\work is a junction to D:\work
say physical('C:\Users\me\work\src'.IO);     # "D:/work/src".IO

# Paths that do not exist yet are kept as far as they go.
say physical('/srv/current/not/yet'.IO);     # "/srv/releases/42/not/yet".IO
```

`physical-path(IO::Path:D $path, Int:D :$max-hops = 40 --> IO::Path:D)` makes `$path` absolute against `$*CWD`, then walks it one component at a time. Every component that is a link — a symlink anywhere, and on Windows a junction too — is replaced by its target and the walk carries on from there, so a link in the middle of a path is followed just like one at the end. The result is absolute and link-free as far as the path exists. Windows paths come back with an upper-case drive letter; `.absolute` gives the native spelling.

### Why not `IO::Path.resolve`

`.resolve` is the right tool on POSIX and the wrong one on Windows. It does not follow symbolic links there, and when it meets a junction it splices the junction's absolute target onto the junction's parent and returns a path that does not exist. `physical-path` is one implementation on every platform.

### `..` follows the platform's rule

The two families disagree about what `..` means once a link is involved, and the resolver has to agree with the OS it runs on, or a path the check calls inside is one the OS opens outside. Take `one/L/../x.txt`, where `L` is a link to `deep/a/b`:

  * **POSIX** resolves `..` physically: it is the parent of wherever the walk has really got to. `L` takes the walk to `deep/a/b`; `..` is `deep/a`; the answer is `deep/a/x.txt`.

  * **Windows** resolves `..` by name. Win32 collapses it out of the path before the filesystem sees it, so the answer is `one/x.txt` and `L` is never consulted. A link whose target is relative is joined onto the link's directory and collapsed the same way before anything in it is followed: a target of `L\..\..\x` climbs two levels from the link, whatever `L` points at.

`t/10-physical-path.rakutest` reads each such path through the OS and checks that `physical-path` names the file the OS opened.

### Failing closed

`physical-path` dies rather than guess when:

  * a link's target cannot be read;

  * a chain is longer than `:max-hops` (a cycle, in practice);

  * on Windows, a link target is drive-relative (`C:foo`, which depends on a per-drive working directory) or a device path (`\\?\…`, `\\.\…`);

  * on Windows, a segment is made of dots and spaces but is not `.` or `..` (Win32 renames such segments on the way in).

### A containment check with it

Resolve both sides, then compare. Resolving only the candidate means a root reached through a link never matches:

```raku
my $root = physical($workspace.IO).absolute;
my $p    = physical($candidate.IO).absolute;
my $sep  = $*SPEC.dir-sep;
die "outside the workspace: $candidate"
    unless $p eq $root || $p.starts-with($root.ends-with($sep) ?? $root !! $root ~ $sep);
```

The comparison is exact-case, so on a case-insensitive filesystem a mismatch in case denies rather than admits. What a resolver cannot defend against is the filesystem changing after the check: resolve, check and open as close together as you can.

Testing
-------

```shell
prove6 -Ilib t/           # with MCP::Server installed
prove6 -Ilib -I../MCP-Server/lib t/    # against a sibling checkout
```

`t/03-containment.rakutest` is the file to read first if you change the resolver: it drives every escape attempt through real tool calls, including symlink escapes, and adapts rather than skips on hosts where creating a symlink is not permitted. `t/10-physical-path.rakutest` pins the resolver itself: it reads each tricky path through the OS and demands that `physical-path` names the file the OS opened, using junctions on Windows so that it needs no privilege there. `t/05-map.rakutest` is the one to read if you change the map: it builds a small polyglot tree whose ranking has one right answer and asserts that answer, rather than asserting that some map came back.

`t/07-grep-parity.rakutest` is the one to read if you touch `grep`. It runs every kind of query through **every searcher installed on the machine** and asserts the answers are identical strings, skipping an arm only when its binary genuinely is not there and saying which. `t/08-grep-backend.rakutest` covers the tier choice itself — that a searcher is probed once, that a probe which got no answer is asked again, and that a search believes only an answer the searcher's documentation calls one: stand-in searchers it writes for itself exit 3, die by a signal part-way through their list, refuse with a message or fail in silence, and the answer and the spawn count show which lists were believed, that a searcher is given up only when its binary has gone or after five untrusted answers in a row, and that `reset-searchers` brings every one back. `t/07` holds the real tools to the same rule with a file in the root that nobody may read. `t/11-handles.rakutest` holds every tool to giving back every file descriptor it takes: it counts the handles the process holds open — from the kernel's own list on Linux and macOS, with `GetProcessHandleCount` on Windows — around a few hundred calls, and runs a hundred searches in a row without losing the external searcher.

Examples
--------

  * `examples/filesystem-server.raku` — a two-root server (writable workspace, read-only reference tree) over stdio.

Author
------

Matt Doughty

License
-------

Artistic-2.0

