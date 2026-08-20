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

### Parameter naming

Parameter names in this pack are a contract, not a matter of taste:

  * Every parameter that names a location is called exactly `path`, or `from` and `to` for the one tool that has two.

  * Multi-word parameters are kebab-case: `old-string`, `new-string`, `replace-all`, `max-results`.

The reason is what sits in front of the server. A permission layer — Claude Code's directory rules, or [MCP::Client::Policy](https://github.com/m-doughty/MCP-Client) — decides whether a call may go through by looking at which files it would touch, and it finds them by name. A tool that called its argument `filename` would sail past a rule written for `path`. If you write a toolkit of your own that is meant to live behind the same guard, use the same names.

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

  * Files that are not UTF-8 text — a NUL byte in the first 8KB, or bytes that will not decode — are skipped, and a trailing notice counts them.

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

`grep` is a reading tool: it is registered even when `read-only` is set.

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

  * **No device names.** Segments Windows resolves to devices regardless of directory — `CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`, with or without an extension — are refused on every platform, so behaviour is identical everywhere rather than only safe where it is tested.

  * **No null bytes.**

  * **Physical-path symlink chase.** The candidate path is built segment by segment under the root; then every symlink in it is chased to its destination — component by component, the way `realpath` works, with a hop budget against cycles — and the *physical* result is checked against the root. A symlink planted inside the sandbox therefore cannot be used as a door out of it, whether it points at a file or a directory, whether directly or through a chain, and whether its target is absolute or relative. The chase is the pack's own (over `readlink`), **not** `IO::Path.resolve`, because `.resolve` does not follow symlinks on Windows — an unfollowed link is an open door the OS walks through at open time even though a check did not. One code path runs on every platform. A link whose target cannot be read, a chain that exceeds the hop budget, and a Windows drive-relative target (`C:foo`) are all refused outright: fail closed.

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

  * On a platform whose `resolve` does not fully canonicalise (older Windows), a pre-planted in-root symlink pointing outside could in principle survive the ancestor check. The `..`/absolute/device rejections still hold; treat the root as a directory you control the contents of.

  * Confinement is not a permission system. Anything the server process can read under the root, the model can read, and on a read-write pack anything it can write, the model can `delete`. Run it as a user with no more access than you intend to grant, use `read-only` unless writes are actually wanted, and put a permission layer in front of it if "the whole root" is more than you meant to hand over.

  * `delete` with `recursive` is `rm -rf`, applied to a path the model chose. It refuses the root itself and it unlinks symlinks rather than following them, but within the root it is exactly as final as it sounds. This is the tool to gate behind a permission layer first.

  * `move` is a rename and only a rename. If the root spans a mount point — a bind mount, a network share grafted into the tree — a move across it fails with the OS's own error instead of silently copying and deleting. Honest, but it means such a move is simply not available; do it with `read` and `write` if you must.

  * Conditional revisions are authoritative among calls through one toolkit instance. An unrelated process writing the same filesystem does not take this lock, so it can still race between the toolkit's comparison and operating-system mutation. Its completed changes are detected by the next comparison; it does not participate atomically.

  * Nothing here rate-limits or size-limits: `read` will happily slurp a huge file into memory, `glob` will walk a huge tree, and `grep` reads every text file below the path it is given (`max-results` bounds the *output*, not the reading). `map` is the one exception — it prunes, skips files over 1MB, stops after 5000 files and bounds its own output — but its first pass over a large tree still costs a parse of every source file in it. Point the pack at a workspace, not at `/`.

Testing
-------

```shell
prove6 -Ilib t/           # with MCP::Server installed
prove6 -Ilib -I../MCP-Server/lib t/    # against a sibling checkout
```

`t/03-containment.rakutest` is the file to read first if you change the resolver: it drives every escape attempt through real tool calls, including symlink escapes, and adapts rather than skips on hosts where creating a symlink is not permitted. `t/05-map.rakutest` is the one to read if you change the map: it builds a small polyglot tree whose ranking has one right answer and asserts that answer, rather than asserting that some map came back.

Examples
--------

  * `examples/filesystem-server.raku` — a two-root server (writable workspace, read-only reference tree) over stdio.

Author
------

Matt Doughty

License
-------

Artistic-2.0

