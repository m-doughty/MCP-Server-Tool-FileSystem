use MCP::Server::Toolkit;
use Digest::SHA256::Native;

# For nqp::readlink in physical-path below.  Rakudo has no public readlink,
# and IO::Path.resolve — the obvious alternative — is documented not to
# follow symlinks on Windows, which is exactly the case the containment
# check exists for.
use nqp;

# The map tool's parsing, ranking and rendering.  Everything in there takes
# bytes and gives back facts; everything in here decides which bytes.
use MCP::Server::Tool::FileSystem::Map;

#| Root-confined filesystem tools for MCP::Server.  Every path a client sends
#| is interpreted relative to $.root and can never reach outside it, so an LLM
#| gets a usable filesystem without getting the whole machine.
unit class MCP::Server::Tool::FileSystem does MCP::Server::Toolkit;

# Rakudo 2026.09 builds $*DISTRO afresh on every read instead of once per
# process: its lazy initialiser files the object it built under the key
# '$*DISTRO', and the lookup only ever asks for '$DISTRO'.  On macOS each
# build runs sw_vers and leaves the pipe it read the answer from open, so
# every read costs a process and a file descriptor that is never given back.
# This pack asks $*DISTRO for every path component it splits, chases or
# compares — a dozen times per fs_read, at least once per file a search
# walks — so a server at macOS's default limit of 256 descriptors ran out
# within a few dozen calls: ripgrep could no longer be started, and then
# nothing could be opened at all.  Filing the object under the key the
# lookup reads makes it the one every later read returns, as on every other
# release; where the key is already there, which is everywhere the bug is
# not, nothing is filed.
#
# Only a real Distro is filed.  A module loaded inside a test's stand-in
# $*DISTRO (`my $*DISTRO = class { method is-win { True } }.new`, the usual
# way to exercise a Windows branch on another OS) reads the stand-in here,
# and filing that would make it the whole process's for good; such a process
# is left to Rakudo's own behaviour instead.
#
# The bug came in with rakudo/rakudo a22cab8f9 (2026-09-02); delete this
# once no supported Rakudo has it.
unless PROCESS::<$DISTRO>:exists {
	my $distro := $*DISTRO;
	PROCESS::<$DISTRO> := $distro
		if $distro ~~ Distro:D && !(PROCESS::<$DISTRO>:exists);
}

has IO::Path() $.root is required;
has Bool:D $.read-only = False;
has Lock $!mutation-lock .= new;

# Per-file parse results for the map tool, keyed by absolute path and valid
# only while the file's mtime and size are unchanged.  Private, so the
# toolkit's from-config key list — which is built from public attributes — is
# unaffected by its existence.  One coarse lock around the whole map body:
# building a map is measured in file reads, not in microseconds, and two
# concurrent maps of the same tree have nothing to gain from interleaving.
has %!map-cache;
has Lock $!map-lock .= new;

my constant REVISION-SCHEME = 'sha256-v1';
my constant EXPECTED-REVISIONS = '_expected-revisions';

# The lock the scanning phase of every grep runs under, whichever tier chose
# the files it looks at.  Module-level rather than per-instance, and declared
# up here rather than beside the rest of the searcher machinery at the foot of
# the file, only because Raku wants a variable declared before the line that
# uses it.  What it is for is in the "External searchers" block down there.
my $grep-scan-lock = Lock.new;

#| The MCP annotations every reading tool in this pack carries: it changes
#| nothing under the root, and calling it again with the same arguments adds
#| nothing to what the first call did.  A host may act on that — C<MCP::Server>
#| runs a batch of them side by side, and de-duplicates identical calls within
#| it — so the claim has to be true of the B<handler>, not merely of the
#| intent: every read path below is either pure, or takes this instance's own
#| lock (the mutation lock for the observation tools, the map lock for the map
#| cache), which is what makes two of them at once safe.
#|
#| The mutating tools deliberately carry none.  A write is not read-only and a
#| C<move> is not idempotent, and a pack that annotated them "for completeness"
#| would be handing a host permission it must not have.
#|
#| A C<Map> rather than a Hash literal: `constant %h = {...}` freezes the
#| container and not the object inside it, so the "constant" could still be
#| mutated in place by whoever it is handed to.
my constant READ-ANNOTATIONS = Map.new((
	readOnlyHint   => True,
	idempotentHint => True,
));

submethod TWEAK {
	die "FileSystem root does not exist or is not a directory: {$!root}"
		unless $!root.d;
	# Resolve once, up front: every containment check compares against this, so
	# it must already be free of symlinks and relative segments.  resolve alone
	# is not enough — it does not follow symlinks on Windows — so the same
	# link chase the resolver uses runs on the root too.
	$!root .= resolve;
	$!root = physical-path($!root);
}

method default-prefix(--> Str) { 'fs' }

# Parameter names here are a contract rather than a matter of taste.  Every
# parameter naming a location is called exactly 'path', 'from' or 'to', and
# multi-word parameters are kebab-case ('old-string', 'max-results').  A
# permission layer in front of the server matches calls by those names to work
# out which files a call would touch, so renaming one — or inventing a
# 'filename' for a seventh tool — silently widens what it waves through.
method register($registrar) {
	$registrar.tool: 'read',
		annotations => READ-ANNOTATIONS,
		description => 'Read a UTF-8 text file from inside the server root. '
			~ 'Paths are relative to that root; absolute paths and ".." are refused. '
			~ 'Give offset and/or limit to read a window of lines instead of the '
			~ 'whole file: that form numbers every line as "N<tab>text", so strip '
			~ 'the number and the tab before passing any of it back as the edit '
			~ "tool's old-string. Windowed lines also lose their line endings, "
				~ 'so for a file with CRLF endings read without offset/limit before '
				~ 'building an old-string.',
		params => {
			path => {
				type        => 'string',
				description => 'File path relative to the root, e.g. "notes/todo.md"',
				required    => True,
			},
			offset => {
				type        => 'integer',
				description => 'First line to read, counting from 1; defaults to the first line',
			},
			limit => {
				type        => 'integer',
				description => 'How many lines to read from offset onwards; defaults to the rest of the file',
			},
		},
		handler => -> :%args {
			my $rel = arg-str(%args, 'path');
			self!observed-result('path' => $rel, -> {
				self!read-file(
					$rel,
				arg-int(%args, 'offset', :optional, :min(1)),
				arg-int(%args, 'limit',  :optional, :min(1)),
				);
			});
		};

	$registrar.tool: 'list',
		annotations => READ-ANNOTATIONS,
		description => 'List the immediate contents of a directory inside the '
			~ 'server root, one entry per line, sorted, directories marked with a '
			~ 'trailing "/".',
		params => {
			path => {
				type        => 'string',
				description => 'Directory path relative to the root; defaults to the root itself',
				default     => '.',
			},
		},
		handler => -> :%args {
			my $rel = arg-str(%args, 'path', :default<.>);
			self!observed-result('path' => $rel, -> { self!list-dir($rel) });
		};

	$registrar.tool: 'glob',
		annotations => READ-ANNOTATIONS,
		description => 'Find files anywhere below a directory by wildcard. '
			~ '"*" matches any run of characters within one path segment, "?" '
			~ 'matches a single character; matching is case-sensitive and regexes '
			~ 'are not accepted. A pattern without a "/" is matched against entry '
			~ 'names at any depth, a pattern with a "/" against the path relative '
			~ 'to the searched directory. Results are paths relative to the root.',
		params => {
			pattern => {
				type        => 'string',
				description => 'Wildcard pattern, e.g. "*.txt" or "src/*.rakumod"',
				required    => True,
			},
			path => {
				type        => 'string',
				description => 'Directory to search below, relative to the root; defaults to the root itself',
				default     => '.',
			},
		},
		handler => -> :%args {
			self!glob-files(arg-str(%args, 'pattern'), arg-str(%args, 'path', :default<.>));
		};

	$registrar.tool: 'stat',
		annotations => READ-ANNOTATIONS,
		description => 'Report the type, size, modification time and access '
			~ 'flags of a path inside the server root.',
		params => {
			path => {
				type        => 'string',
				description => 'Path relative to the root',
				required    => True,
			},
		},
		handler => -> :%args {
			my $rel = arg-str(%args, 'path');
			self!observed-result('path' => $rel, -> { self!stat-path($rel) });
		};

	$registrar.tool: 'grep',
		annotations => READ-ANNOTATIONS,
		description => 'Search the files below a directory inside the server root '
			~ 'for lines containing a pattern, reported as "path:line:text". The '
			~ 'pattern is literal text unless regex is set, in which case it is a '
			~ 'Raku regex and not a PCRE one: classes, quantifiers, alternation and '
			~ 'anchors read the same, but a space is not literal unless quoted and a '
			~ 'pattern carrying a code block is refused. Files that are not UTF-8 '
			~ 'text are skipped, and the search stops once max-results lines '
			~ 'have matched.',
		params => {
			pattern => {
				type        => 'string',
				description => 'Text to search for, or a Raku regex when regex is true',
				required    => True,
			},
			path => {
				type        => 'string',
				description => 'File to search, or directory to search below, relative to the root; defaults to the root itself',
				default     => '.',
			},
			regex => {
				type        => 'boolean',
				description => 'Treat pattern as a Raku regex instead of literal text; defaults to false',
				default     => False,
			},
			glob => {
				type        => 'string',
				description => 'Only search files whose name matches this wildcard, e.g. "*.raku"; may not contain "/"',
				default     => '',
			},
			'context' => {
				type        => 'integer',
				description => 'Lines of surrounding context to show around each match, 0 to 20; defaults to 0',
				default     => 0,
			},
			'max-results' => {
				type        => 'integer',
				description => 'Stop after this many matching lines, 1 to 1000; defaults to 50',
				default     => 50,
			},
		},
		handler => -> :%args {
			self!grep-files(
				arg-str(%args, 'pattern'),
				arg-str(%args, 'path', :default<.>),
				arg-bool(%args, 'regex'),
				arg-str(%args, 'glob', :default('')),
				arg-int(%args, 'context', :default(0), :min(0), :max(20)),
				arg-int(%args, 'max-results', :default(50), :min(1), :max(1000)),
			);
		};

	$registrar.tool: 'map',
		annotations => READ-ANNOTATIONS,
		description => 'Map the shape of the code below a directory before '
			~ 'reading files: the highest-ranked files as skeletons — path plus '
			~ 'the definition lines of their most-referenced symbols, never '
			~ 'bodies — ranked by how much the rest of the tree references them. '
			~ 'Start here to orient, then read only what matters. Pass query to '
			~ 'pull the map toward identifiers or topics, and focus to weight '
			~ 'named files heavily. Understands C, C++, Go, Java, JavaScript, '
			~ 'Python, Rust, TypeScript and Raku; other files are skipped and '
			~ 'counted.',
		params => {
			path => {
				type        => 'string',
				description => 'Directory to map, relative to the root; defaults to the root itself',
				default     => '.',
			},
			query => {
				type        => 'string',
				description => 'Space-separated identifiers or words to focus the map on; matching files and symbols rank higher',
				default     => '',
			},
			focus => {
				type        => 'string',
				description => 'Space- or comma-separated file paths, relative to the root, to weight heavily',
				default     => '',
			},
			'max-chars' => {
				type        => 'integer',
				description => 'Upper bound on the size of the map in characters, 512 to 65536; defaults to 8192',
				default     => 8192,
			},
		},
		handler => -> :%args {
			self!map-repo(
				arg-str(%args, 'path', :default<.>),
				arg-str(%args, 'query', :default('')),
				arg-str(%args, 'focus', :default('')),
				arg-int(%args, 'max-chars', :default(8192), :min(512), :max(65536)),
			);
		};

	# A read-only pack does not merely refuse writes at call time: the mutating
	# tools are never advertised, so the model is not tempted to try.
	return if $!read-only;

	$registrar.tool: 'write',
		description => 'Write UTF-8 text to a file inside the server root, '
			~ 'replacing any existing contents. The parent directory must '
			~ 'already exist — create it with the mkdir tool first.',
		params => {
			path => {
				type        => 'string',
				description => 'File path relative to the root',
				required    => True,
			},
			content => {
				type        => 'string',
				description => 'Text to write',
				required    => True,
			},
		},
		handler => -> :%args {
			my $rel = arg-str(%args, 'path');
			self!mutation-result(
				%args, ['path' => $rel],
				-> { self!write-file($rel, arg-str(%args, 'content')) },
			);
		};

	$registrar.tool: 'mkdir',
		description => 'Create a directory inside the server root, including any '
			~ 'missing parent directories.',
		params => {
			path => {
				type        => 'string',
				description => 'Directory path relative to the root',
				required    => True,
			},
		},
		handler => -> :%args {
			my $rel = arg-str(%args, 'path');
			self!mutation-result(%args, ['path' => $rel], -> { self!make-dir($rel) });
		};

	$registrar.tool: 'edit',
		description => 'Replace an exact run of text in a file inside the server '
			~ 'root, leaving the rest of the file byte for byte as it was. '
			~ 'old-string must match exactly — whitespace, indentation and line '
			~ 'endings included — and must appear exactly once unless replace-all '
			~ 'is set, so read the file first and quote enough of it to be unique.',
		params => {
			path => {
				type        => 'string',
				description => 'File path relative to the root',
				required    => True,
			},
			'old-string' => {
				type        => 'string',
				description => 'Exact text to find, including its indentation',
				required    => True,
			},
			'new-string' => {
				type        => 'string',
				description => 'Text to put in its place; an empty string deletes the match',
				required    => True,
			},
			'replace-all' => {
				type        => 'boolean',
				description => 'Replace every occurrence instead of insisting on a unique one; defaults to false',
				default     => False,
			},
		},
		handler => -> :%args {
			my $rel = arg-str(%args, 'path');
			self!mutation-result(%args, ['path' => $rel], -> {
				self!edit-file(
					$rel,
				arg-str(%args, 'old-string'),
				arg-str(%args, 'new-string'),
				arg-bool(%args, 'replace-all'),
				);
			});
		};

	$registrar.tool: 'move',
		description => 'Rename a file or directory inside the server root, or move '
			~ 'it somewhere else inside that root. The destination must not already '
			~ 'exist and its parent directory must, so nothing is overwritten by a '
			~ 'typo; a directory moves with everything inside it.',
		params => {
			from => {
				type        => 'string',
				description => 'Existing path relative to the root',
				required    => True,
			},
			to => {
				type        => 'string',
				description => 'New path relative to the root, including the new name',
				required    => True,
			},
		},
		handler => -> :%args {
			my $from = arg-str(%args, 'from');
			my $to = arg-str(%args, 'to');
			self!mutation-result(
				%args, ['from' => $from, 'to' => $to],
				-> { self!move-path($from, $to) },
			);
		};

	$registrar.tool: 'delete',
		description => 'Delete a file or directory inside the server root. A '
			~ 'directory must be empty unless recursive is set, in which case '
			~ 'everything below it is deleted too and none of it is recoverable.',
		params => {
			path => {
				type        => 'string',
				description => 'Path relative to the root',
				required    => True,
			},
			recursive => {
				type        => 'boolean',
				description => 'Delete a non-empty directory and its whole contents; defaults to false',
				default     => False,
			},
		},
		handler => -> :%args {
			my $rel = arg-str(%args, 'path');
			self!mutation-result(
				%args, ['path' => $rel],
				-> { self!delete-path($rel, arg-bool(%args, 'recursive')) },
			);
		};
}

# === Optimistic concurrency results ===

# Read observations and mutations return the same text block they always did,
# plus a machine-only revision map.  The provider bridge keeps that map out of
# model-visible content while making it available to MCP::Client::Leases.
method !observed-result(Pair:D $location, &action --> Hash:D) {
	$!mutation-lock.protect: {
		my $text = action();
		self!tool-result($text, [$location]);
	}
}

# `_expected-revisions` is intentionally absent from every advertised schema.
# A lease composer adds it after the model has produced the call.  When it is
# present it is all-or-nothing: every named mutation location must have a token,
# and compare + mutation happen under this toolkit instance's one mutation lock.
method !mutation-result(%args, @locations, &action --> Hash:D) {
	my $raw = %args{EXPECTED-REVISIONS};
	my $conditional = %args{EXPECTED-REVISIONS}:exists;

	if $conditional {
		die "Parameter '{EXPECTED-REVISIONS}' must be an object of location names to revision tokens"
			unless $raw ~~ Associative;
		my %expected = $raw.Hash;
		my @wanted = @locations.map(*.key).List;
		my @missing = @wanted.grep({
			!(%expected{$_}:exists) || %expected{$_} !~~ Str:D
		});
		my @extra = %expected.keys.grep(-> $key {
			!@wanted.first(-> $wanted { $wanted eq $key }).defined
		}).sort;
		die "Parameter '{EXPECTED-REVISIONS}' must contain a string token for "
			~ @missing.map({ "'$_'" }).join(', ')
			if @missing;
		die "Parameter '{EXPECTED-REVISIONS}' contains unknown location "
			~ @extra.map({ "'$_'" }).join(', ')
			if @extra;
	}

	$!mutation-lock.protect: {
		if $conditional {
			my %expected = $raw.Hash;
			for @locations -> $location {
				my %current = self!revision($location.value.Str);
				next if %current<token> eq %expected{$location.key};
				die "Stale filesystem observation for '{$location.value}': "
					~ "the expected revision no longer matches. Re-read or stat the path, "
					~ 'then reacquire its lease before trying again';
			}
		}

		my $text = action();
		self!tool-result($text, @locations);
	}
}

method !tool-result(Str:D $text, @locations --> Hash:D) {
	my %revisions;
	for @locations -> $location {
		%revisions{$location.key} = self!revision($location.value.Str);
	}
	%(
		content => [%( type => 'text', :$text ),],
		structuredContent => %(
			revisionScheme => REVISION-SCHEME,
			revisions => %revisions,
		),
	);
}

# A revision is about bytes and tree identity, never mtimes.  Directory input
# is a length-framed, path-sorted list so neither traversal order nor ambiguous
# separators can change the digest.  Symlinks are recorded as links and are not
# followed, matching the recursive tool safety policy.
method !revision(Str:D $rel --> Hash:D) {
	my $path = self!resolve($rel);
	return %( state => 'absent', token => REVISION-SCHEME ~ ':absent' )
		unless $path.e || $path.l;

	if $path.f && !$path.l {
		my $bytes = try $path.slurp(:bin);
		die "Could not compute revision for '$rel': {error-line($!)}" without $bytes;
		return %(
			state => 'file',
			token => REVISION-SCHEME ~ ':file:' ~ sha256-hex($bytes),
		);
	}

	if $path.d && !$path.l {
		my @records;
		self!revision-tree($path, '', @records);
		return %(
			state => 'directory',
			token => REVISION-SCHEME ~ ':directory:'
				~ sha256-hex(@records.sort.join.encode('utf-8')),
		);
	}

	# A direct path may name an in-root symlink. Its target text is what can
	# change without altering its display name; hash that text, not the target.
	if $path.l {
		my $target = try nqp::readlink($path.Str);
		die "Could not compute revision for symlink '$rel': {error-line($!)}"
			without $target;
		return %(
			state => 'symlink',
			token => REVISION-SCHEME ~ ':symlink:' ~ sha256-hex($target.Str),
		);
	}

	%(
		state => 'other',
		token => REVISION-SCHEME ~ ':other:' ~ sha256-hex($path.Str),
	);
}

method !revision-tree(IO::Path:D $dir, Str:D $prefix, @records is raw --> Nil) {
	my $entries = try $dir.dir.List;
	die "Could not compute directory revision for '{$dir.basename}': {error-line($!)}"
		without $entries;

	for $entries.sort(*.basename) -> $entry {
		my $name = $prefix.chars ?? "$prefix/{$entry.basename}" !! $entry.basename;
		my $framed = $name.encode('utf-8').bytes ~ ':' ~ $name ~ ':';
		if $entry.l {
			my $target = try nqp::readlink($entry.Str);
			die "Could not compute directory revision at '$name': {error-line($!)}"
				without $target;
			@records.push: 'L:' ~ $framed ~ sha256-hex($target.Str);
		}
		elsif $entry.d {
			@records.push: 'D:' ~ $framed;
			self!revision-tree($entry, $name, @records);
		}
		elsif $entry.f {
			my $bytes = try $entry.slurp(:bin);
			die "Could not compute directory revision at '$name': {error-line($!)}"
				without $bytes;
			@records.push: 'F:' ~ $framed ~ $bytes.bytes ~ ':' ~ sha256-hex($bytes);
		}
		else {
			@records.push: 'O:' ~ $framed;
		}
	}
}

# === Tool implementations ===

method !read-file(Str:D $rel, Int $offset, Int $limit --> Str:D) {
	my $path = self!resolve($rel);
	die "File not found: '$rel'" unless $path.e;
	die "'$rel' is a directory; use the list tool instead" if $path.d;

	my Str $why;
	my $text = slurp-text($path, $why);
	die "Could not read '$rel' as UTF-8 text: $why" without $text;

	# Asking for no range gets no presentation: the whole file comes back
	# exactly as it sits on disk, line endings and all.
	return $text unless $offset.defined || $limit.defined;

	my @lines      = $text.lines;
	my Int:D $total = @lines.elems;
	my Int:D $first = $offset // 1;
	# Reading past the end is how a model discovers where the end is, so it is
	# an answer rather than a failure.
	return "'$rel' has $total lines; offset $first is past the end"
		if $first > $total;

	my Int:D $last = $limit.defined ?? min($total, $first + $limit - 1) !! $total;
	(
		|($first .. $last).map({ $_ ~ "\t" ~ @lines[$_ - 1] }),
		'',
		"[lines $first-$last of $total total]",
	).join("\n");
}

method !edit-file(Str:D $rel, Str:D $old, Str:D $new, Bool:D $replace-all --> Str:D) {
	die "Parameter 'old-string' must not be empty; it is the text to find, not a position"
		if $old eq '';
	die "Parameter 'old-string' and 'new-string' are identical; there is nothing to change"
		if $old eq $new;

	my $path = self!resolve($rel);
	die "File not found: '$rel'" unless $path.e;
	die "'$rel' is a directory; edit a file inside it instead" if $path.d;

	my Str $why;
	my $text = slurp-text($path, $why);
	die "Could not read '$rel' as UTF-8 text: $why" without $text;

	my Int:D $found = $text.indices($old).elems;
	die "No occurrence of 'old-string' in '$rel'; read the file first and quote "
		~ 'it exactly, including indentation and line endings'
		if $found == 0;
	die "Found $found occurrences of 'old-string' in '$rel'; quote more of the "
		~ 'surrounding text to pick one out, or set replace-all to true'
		if $found > 1 && !$replace-all;

	my $updated = $replace-all ?? $text.subst($old, $new, :g) !! $text.subst($old, $new);
	# Written as bytes, not text: the encode here is the only place line
	# endings could be rewritten, and it does not touch them.
	my $bytes = $updated.encode('utf-8');
	check-io($path.spurt($bytes), "Failed to write '$rel'");

	my Int:D $done  = $replace-all ?? $found !! 1;
	my Str:D $times = $done == 1 ?? 'occurrence' !! 'occurrences';
	"Replaced $done $times in '$rel'; wrote {$bytes.bytes} bytes";
}

method !write-file(Str:D $rel, Str:D $content --> Str:D) {
	my $path = self!resolve($rel);
	die "'$rel' is a directory; refusing to overwrite it" if $path.d;
	die "Parent directory of '$rel' does not exist; create it with the mkdir tool first"
		unless $path.parent.d;

	check-io($path.spurt($content), "Failed to write '$rel'");
	"Wrote {$content.encode('utf-8').bytes} bytes to '$rel'";
}

method !list-dir(Str:D $rel --> Str:D) {
	my $dir = self!resolve($rel);
	die "Directory not found: '$rel'" unless $dir.e;
	die "'$rel' is not a directory; use the stat tool instead" unless $dir.d;

	my $entries = try $dir.dir.List;
	die "Could not list '$rel': {error-line($!)}" without $entries;

	my @lines = $entries.map({ .basename ~ (.d ?? '/' !! '') }).sort;
	@lines ?? @lines.join("\n") !! '(empty directory)';
}

method !glob-files(Str:D $pattern, Str:D $rel --> Str:D) {
	die 'Pattern must not be empty' if $pattern eq '';
	my $dir = self!resolve($rel);
	die "Directory not found: '$rel'" unless $dir.e;
	die "'$rel' is not a directory" unless $dir.d;

	my Bool:D $deep  = $pattern.contains('/') || $pattern.contains('\\');
	my @base         = relative-parts($!root, $dir);
	my @matches;

	walk-tree($dir, -> $entry, @parts {
		@matches.push: (|@base, |@parts).join('/')
			if glob-match($pattern, $deep ?? @parts.join('/') !! $entry.basename);
		True;   # never stop early: a glob reports everything it finds
	});

	@matches ?? @matches.sort.join("\n") !! "No matches for '$pattern' under '$rel'";
}

method !grep-files(
	Str:D $pattern, Str:D $rel, Bool:D $regex, Str:D $glob,
	Int:D $context, Int:D $max --> Str:D
) {
	die 'Pattern must not be empty' if $pattern eq '';
	die "The glob parameter filters file names only and may not contain a separator: '$glob'"
		if $glob.contains('/') || $glob.contains('\\');

	# Interpolating a client's string into a real regex is only safe because
	# Rakudo refuses, by default, to interpolate one containing a code block:
	# /<$pattern>/ on `{ unlink "x" }` is an error, not an execution.  NEVER add
	# `use MONKEY-SEE-NO-EVAL` to this file — that pragma exists to turn this
	# exact guard off, and turning it off here turns a search tool into remote
	# code execution.  t/02-tools.rakutest asserts the refusal.
	#
	# The trial match below is what compiles the pattern, so both that refusal
	# and an ordinary syntax error surface here as one clear message rather
	# than at some arbitrary line of some file half a tree in.
	if $regex {
		my $compiles = try { '' ~~ /<$pattern>/; True };
		die "Invalid regex pattern '$pattern': {error-line($!)}" without $compiles;
	}

	my $target = self!resolve($rel);
	die "Path not found: '$rel'" unless $target.e;

	# Which files the scan below will even open, chosen by an external searcher
	# when there is one that can answer this question identically — see the
	# "External searchers" section for what that costs and why.  Deliberately
	# outside the scan lock: this is the part that is allowed to run in
	# parallel.  An undefined Set means "no list": scan everything.
	my $candidates = $target.d && !$regex && externally-searchable($pattern)
		?? external-candidates($pattern, $target)
		!! Set;

	my @base = relative-parts($!root, $target);
	my @out;
	my Int:D $matched = 0;

	# Returns False once the result budget is spent, which stops the walk.
	my sub scan(IO::Path:D $file, Str:D $display --> Bool:D) {
		return True unless $file.f;
		return True if $glob ne '' && !glob-match($glob, $file.basename);
		# A file an external searcher looked at and did not name cannot contain
		# the pattern, so it is never opened.  The ones it could not have
		# looked at — symlinks, names carrying a line break — are opened
		# regardless: its silence says nothing about them.
		if $candidates.defined && !unreportable-file($file) {
			return True unless $candidates{search-key($file.absolute)};
		}
		# A symlink inside the root may point outside it.  The walk already
		# refuses to descend symlinked directories; this is the same rule for
		# the files themselves, so a planted link cannot be read out through
		# a search the way it cannot be read out through the read tool.
		# physical-path rather than .resolve, which does not follow links on
		# Windows; a link that cannot be chased is skipped like an unreadable
		# file — fail closed, keep searching.
		if $file.l {
			my $physical = try physical-path($file);
			return True without $physical;
			return True unless path-contains($!root, $physical);
		}

		my $bytes = try $file.slurp(:bin);
		return True without $bytes;   # unreadable: skipped like an unreadable directory
		# Binary and mis-encoded files are passed over in silence.  They used
		# to be counted in a trailing notice, and that notice is gone: an
		# external searcher skips a binary file without saying so, and one
		# answer the model cannot tell the tiers apart by is worth more than
		# the count was.
		return True if looks-binary($bytes);
		my Str $why;
		my $text = decode-text($bytes, $why);
		return True without $text;

		my @lines = $text.lines;
		my @hits  = (^@lines).grep({
			$regex ?? so(@lines[$_] ~~ /<$pattern>/) !! @lines[$_].contains($pattern)
		});
		return True unless @hits;

		my @taken = @hits.head($max - $matched);
		$matched += @taken.elems;

		# Context turns each hit into a window; overlapping windows merge, and
		# a gap between them prints GNU grep's '--' separator.
		my @hit is default(False);
		my @show is default(False);
		for @taken -> $i {
			@hit[$i] = True;
			@show[$_] = True for max(0, $i - $context) .. min(@lines.end, $i + $context);
		}

		my Int:D $previous = -2;   # far enough back that the first line is never contiguous
		for ^@lines -> $i {
			next unless @show[$i];
			@out.push('--') if $context > 0 && @out.elems && $i != $previous + 1;
			my Str:D $sep = @hit[$i] ?? ':' !! '-';
			@out.push($display ~ $sep ~ ($i + 1) ~ $sep ~ @lines[$i]);
			$previous = $i;
		}

		$matched < $max;
	}

	# One process-wide lock around the whole walk-and-read phase, on every
	# tier.  On the Raku tier it is what keeps concurrent searches from killing
	# the VM outright; on the external tiers the candidate list is short and
	# the lock is held for almost no time at all.
	$grep-scan-lock.protect: {
		if $target.d {
			walk-tree($target, -> $entry, @parts { scan($entry, (|@base, |@parts).join('/')) });
		} else {
			scan($target, @base.join('/'));
		}
	}

	my @notices;
	if $matched >= $max {
		my Str:D $lines = $max == 1 ?? 'line' !! 'lines';
		@notices.push: "[stopped at $max matching $lines; raise max-results to see more]";
	}

	return ("No matches for '$pattern' under '$rel'", |@notices).join("\n") unless @out.elems;
	(|@out, |(@notices.elems ?? ('', |@notices) !! ())).join("\n");
}

method !map-repo(Str:D $rel, Str:D $query, Str:D $focus, Int:D $max-chars --> Str:D) {
	my $dir = self!resolve($rel);
	die "Directory not found: '$rel'" unless $dir.e;
	die "'$rel' is not a directory; map the directory it lives in instead"
		unless $dir.d;

	# Paths in the map are relative to the ROOT, not to the mapped directory,
	# so a path in the map can be handed straight back to the read tool.
	my @base = relative-parts($!root, $dir);
	my @focus-paths = focus-paths($focus);

	$!map-lock.protect: {
		my $scanner = Scanner.new;
		LEAVE { $scanner.dispose if $scanner.defined }

		my ($files, $stopped) = collect-map-files($dir, $!root, MAP-FILE-LIMIT);
		my %tags;
		my Int:D $skipped = 0;

		for $files.list -> %file {
			my $entry = %file<io>;

			# Cheapest test first, and it is only a name: a tree is mostly
			# files the map has no way to read, and none of them get opened.
			my Str $lang = lang-for($entry.basename);
			without $lang {
				$skipped++;
				next;
			}

			my Int:D $size = ((try $entry.s) // 0).Int;
			if $size > MAP-MAX-FILE-BYTES {
				$skipped++;
				next;
			}

			# The cache is what makes the second map of a working tree
			# nearly free, which is the case that matters: an agent maps,
			# edits one file, and maps again.  mtime alone would miss an
			# edit that landed inside one filesystem timestamp tick, so the
			# size has to match too.
			my Str:D $key = $entry.absolute;
			my $mtime = (try file-mtime($entry)) // Instant;
			my $cached = %!map-cache{$key};
			my Str:D $path = (|@base, |%file<parts>).join('/');
			if $cached.defined && $cached<tags>.defined
			&& $cached<size> == $size
			&& $mtime.defined && $cached<mtime>.defined
			&& $cached<mtime> == $mtime {
				%tags{$path} = $cached<tags>;
				next;
			}

			my $bytes = try $entry.slurp(:bin);
			without $bytes {
				$skipped++;   # unreadable: skipped like an unreadable directory
				next;
			}
			if looks-binary($bytes) {
				$skipped++;
				next;
			}

			my $tags = try extract-tags($bytes, $lang, $scanner);
			without $tags {
				$skipped++;
				next;
			}
			%!map-cache{$key} = %( :$mtime, :$size, :$tags );
			%tags{$path} = $tags;
		}

		my %ranked = rank-files(%tags, $query, @focus-paths);
		my @ordered = order-files(%tags, %ranked<ranks>);
		my @blocks = @ordered.map(-> $path {
			%(
				:$path,
				defs => order-defs(%tags{$path}, %ranked<weights>).Array,
			);
		});

		my @seeds;
		@seeds.push: 'query' if query-words($query);
		@seeds.push: 'focus' if @focus-paths;

		# Parenthesised on purpose: a reduction is a list operator, and an
		# unparenthesised one inside a hash literal swallows every pair to
		# its right.
		my Int:D $definitions = ([+] @blocks.map({ .<defs>.elems })) // 0;

		render-map(@blocks, $max-chars, %(
			mapped      => %tags.elems,
			skipped     => $skipped,
			definitions => $definitions,
			seeds       => @seeds,
			stopped     => $stopped,
		));
	}
}

method !move-path(Str:D $from-rel, Str:D $to-rel --> Str:D) {
	my $from = self!resolve($from-rel);
	my $to   = self!resolve($to-rel);

	die "Path not found: '$from-rel'" unless $from.e || $from.l;
	die 'Refusing to move the server root itself' if $from.absolute eq $!root.absolute;
	die "Destination '$to-rel' already exists; delete it or pick another name"
		if $to.e || $to.l;
	die "Parent directory of '$to-rel' does not exist; create it with the mkdir tool first"
		unless $to.parent.d;

	# No copy-and-delete fallback: on the one filesystem the root lives on a
	# rename is atomic, and anything that is not one file system should say so
	# rather than half-move a tree.
	check-io($from.rename($to), "Failed to move '$from-rel' to '$to-rel'");
	"Moved '$from-rel' to '$to-rel'";
}

method !delete-path(Str:D $rel, Bool:D $recursive --> Str:D) {
	my $path = self!resolve($rel);
	die "Path not found: '$rel'" unless $path.e || $path.l;
	die 'Refusing to delete the server root itself' if $path.absolute eq $!root.absolute;

	# A symlink is deleted as the link it is, never as the thing it points at.
	if $path.d && !$path.l {
		if $recursive {
			delete-tree($path, $rel);
			return "Deleted directory '$rel' and everything below it";
		}
		my $entries = try $path.dir.List;
		die "Could not read directory '$rel': {error-line($!)}" without $entries;
		die "Directory '$rel' is not empty; set recursive to true to delete it and everything below it"
			if $entries.elems;
		check-io($path.rmdir, "Failed to delete directory '$rel'");
		return "Deleted empty directory '$rel'";
	}

	check-io($path.unlink, "Failed to delete '$rel'");
	"Deleted file '$rel'";
}

method !stat-path(Str:D $rel --> Str:D) {
	my $path = self!resolve($rel);
	die "Path not found: '$rel'" unless $path.e;

	my $modified = try file-mtime($path);
	(
		'path: '     ~ (relative-parts($!root, $path).join('/') || '.'),
		'type: '     ~ ($path.d ?? 'directory' !! $path.f ?? 'file' !! 'other'),
		'size: '     ~ ((try $path.s) // 0),
		'modified: ' ~ ($modified.defined
			?? $modified.DateTime.utc.truncated-to('second').Str
			!! 'unknown'),
		'symlink: '  ~ ($path.l ?? 'yes' !! 'no'),
		'readable: ' ~ ($path.r ?? 'yes' !! 'no'),
		# A read-only pack reports nothing as writable, whatever the mode bits
		# say, because no tool here can write it.
		'writable: ' ~ (!$!read-only && $path.w ?? 'yes' !! 'no'),
	).join("\n");
}

method !make-dir(Str:D $rel --> Str:D) {
	my $path = self!resolve($rel);
	return "Directory already exists: '$rel'" if $path.d;
	die "'$rel' already exists and is not a directory" if $path.e;

	check-io($path.mkdir, "Failed to create directory '$rel'");
	"Created directory '$rel'";
}

# === Containment ===

# Segments Windows resolves to devices no matter which directory they appear
# in — writing root/NUL would leave the sandbox there.  Refused on every
# platform so behaviour (and the test suite) is identical everywhere.  COM and
# LPT take any digit, the superscripts ¹ ² ³ included (Windows reads those as
# 1, 2 and 3), and the name is compared as Windows compares it: what comes
# before the first dot, trailing spaces dropped, so 'NUL .txt' is NUL too.
my constant RESERVED-SEGMENTS = set flat
	<con prn aux nul conin$ conout$>,
	(|(0 .. 9), '¹', '²', '³').map({ "com$_", "lpt$_" });

#|( Internal: why Windows would open some other name than the segment says,
    or an undefined Str when it would open exactly that name.  On Windows a
    relative path's segments must not:

    =item contain a C<:> — C<x:stream> is a data stream of C<x>, and
          C<j::$INDEX_ALLOCATION> is the directory C<j> itself, whatever kind
          of link it is;
    =item end in a dot or a space — Win32 drops them, so C<secret.> IS
          C<secret>;
    =item look like an 8.3 short name — a base of up to eight characters
          holding a C<~> and a letter or digit, and at most a three-letter
          extension (C<SECRET~1>, C<PROGRA~1.TXT>, a Samba server's
          C<SECRE~A1>).  Windows still opens a file by the short name it
          gave it, so a client-side rule about C<secret> could be walked past
          by C<SECRET~1>; the long name always works.

    Pure string work, so the rule is tested on every host.  Exposed with
    C<our> scope for the containment tests — not part of the public API. )
our sub windows-segment-hazard(Str:D $segment --> Str) {
	return "it contains ':', which names a data stream on Windows"
		if $segment.contains(':');
	return 'it ends in a dot or a space, which Windows drops'
		if $segment ~~ / <[.\x20]> $ /;
	return "it has the shape of an 8.3 short name, which Windows may resolve to a "
		~ "different long name: use the file's full name"
		if $segment ~~ / ^ $<base>=[<-[.]> ** 1..8] [ '.' <-[.]> ** 1..3 ]? $ /
		&& ~$<base> ~~ / '~' <[A..Za..z0..9]> /;
	Str;
}

#| Turn a client-supplied relative path into an IO::Path under $.root, or die.
#| Three layers, deliberately redundant: textual rejection of anything that
#| could be absolute, a ban on ".." segments, and a physical-path check that
#| chases every symlink itself and catches links pointing out of the sandbox.
#| On Windows a fourth: a segment Windows would read as some other name (see
#| windows-segment-hazard) is refused, so the name a client's permission rules
#| judged is the name the OS opens.
method !resolve(Str:D $rel --> IO::Path:D) {
	die 'Path must not be empty' if $rel eq '';
	die "Path must not contain a null byte: '$rel'" if $rel.contains("\0");

	die "Path must be relative to the configured root: '$rel'"
		if $rel ~~ /^ <[\/\\]> /                    # absolute POSIX / backslash-rooted
		|| $rel ~~ /^ <[A..Za..z]> ':' /            # Windows drive
		|| $rel.starts-with('\\\\');                # UNC

	my @parts = $rel.split(/<[\/\\]>+/).grep({ .chars && $_ ne '.' });
	die "Path may not contain '..' segments: '$rel'"
		if @parts.first(* eq '..').defined;
	die "Path may not use a reserved device name: '$rel'"
		if @parts.first({ RESERVED-SEGMENTS{.split('.').head.trim-trailing.lc} }).defined;
	if $*DISTRO.is-win {
		for @parts -> $part {
			with windows-segment-hazard($part) -> $why {
				die "Path segment '$part' is refused on Windows, because $why: '$rel'";
			}
		}
	}

	# Added one segment at a time so no separator spelling reaches IO::Spec.
	my $candidate = $!root;
	$candidate .= add($_) for @parts;

	# Symlink defence: chase every link in the path ourselves and check the
	# PHYSICAL destination against the root, so a link planted inside the
	# sandbox cannot be used as a door out of it.  IO::Path.resolve would be
	# the obvious tool, but it does not follow symlinks on Windows — and an
	# unfollowed link is an open door, because the OS follows it at open time
	# even though the check did not.  physical-path is the same code on every
	# platform.  Components that do not exist yet cannot be links, so a path
	# about to be written is chased exactly as far as it really goes.
	die "Path escapes the configured root: '$rel'"
		unless path-contains($!root, physical-path($candidate));

	$candidate;
}

#|( The physical path: every symlink chased to its destination, component by
    component, so the answer is the place the operating system will actually
    open.  Exists because IO::Path.resolve does not follow links on Windows
    (and mis-joins a junction's absolute target onto its parent when it
    tries), and a containment check is only as good as the resolution it
    checks.  One code path on every platform, with each platform's own rule
    for '..': on POSIX it is physical — the parent of wherever the walk has
    really got to, the way realpath does it; on Windows it is by NAME — Win32
    collapses '..' out of a path before the filesystem sees it, and a relative
    link target is joined onto the link's directory and collapsed the same way
    before anything inside it is followed.  Junctions and directory symlinks
    are links here like any other.  Fails closed: dies when a link target
    cannot be read, when a chain exceeds :max-hops (a cycle, in practice), and
    on Windows when a link target is drive-relative ('C:foo') or a device path
    ('\\?\…', '\\.\…'), or when a path segment is made of dots and spaces
    but is not '.' or '..'.  Public: see "Resolving a path the way the OS
    will" in the README. )
our sub physical-path(IO::Path:D $path, Int:D :$max-hops = 40 --> IO::Path:D) {
	my ($volume, @todo) = split-absolute($path.absolute);
	@todo = collapse-dots(@todo, $path.absolute) if $*DISTRO.is-win;
	my Str @out;
	my Int $hops = 0;

	while @todo {
		my Str $part = @todo.shift.Str;
		next if $part eq '' || $part eq '.';
		if $part eq '..' {
			# POSIX only (Windows collapsed every '..' by name before the
			# walk).  The chased prefix is link-free, so popping a component
			# is what the kernel itself does — this is what makes a link to
			# 'a/../b' land where the OS would land it.
			@out.pop if @out;
			next;
		}

		my IO::Path $cur = join-parts($volume, (|@out, $part));
		unless $cur.l {
			@out.push: $part;
			next;
		}

		die "Symlink chain is too long at '$cur' — refusing a probable cycle"
			if ++$hops > $max-hops;

		my $target = try nqp::readlink($cur.absolute);
		die "Cannot read the symlink at '$cur' — refusing rather than guessing where it points"
			without $target;

		if $*DISTRO.is-win {
			# The chased prefix is the link's directory as the OS now names
			# it: every earlier link in the path has already been replaced by
			# its target.  Start the walk again on what Windows opens next.
			($volume, @todo) = windows-reparse($volume, @out, $target, @todo,
				link => $cur.Str);
			@out = ();
			next;
		}

		# POSIX: only '/' separates and only a leading '/' restarts the walk.
		# A backslash is an ordinary filename character here.
		@out = () if $target.starts-with('/');
		@todo.prepend: $target.split('/').grep(*.chars);
	}

	join-parts($volume, @out);
}

#|( Internal: the path Windows opens next when a walk reaches a link, as
    (volume, components...).  @prefix is the link's directory, @rest is what
    followed the link in the path being opened.  An absolute target (drive-
    rooted or UNC) replaces the volume and the prefix; a separator-rooted one
    ('\x') keeps the volume and drops the prefix; anything else is joined onto
    the prefix.  Either way the result is collapsed by name, as Win32 does,
    before any of it is followed: a target of 'L\..\..\x' climbs two levels
    from the link's directory whatever L points at.  Pure string work, so it
    is tested on every host.  Exposed with `our` scope for the containment
    tests — not part of the public API. )
our sub windows-reparse(Str:D $volume, @prefix, Str:D $target, @rest,
                        Str:D :$link = '?' --> List:D) {
	die "Symlink at '$link' has a device-path target '$target' — refusing"
		if $target ~~ /^ <[\/\\]> ** 2 <[?.]> [ <[\/\\]> | $ ] /;
	if $target ~~ /^ [ '\\\\' | '//' ] /
	|| $target ~~ /^ <[A..Za..z]> ':' <[\/\\]> / {
		my ($v, @tc) = split-windows($target);
		return ($v, |collapse-dots((|@tc, |@rest), $target));
	}
	# A drive-relative target ('C:foo') depends on a per-drive working
	# directory this process does not track.
	die "Symlink at '$link' has a drive-relative target '$target' — refusing"
		if $target ~~ /^ <[A..Za..z]> ':' /;
	my @base = $target ~~ /^ <[\/\\]> / ?? () !! @prefix;
	($volume, |collapse-dots((|@base, |$target.split(/<[\/\\]>+/), |@rest), $target));
}

# Components with '.' and '..' resolved by name, the way Win32 normalises a
# path: '..' removes the component before it and stops at the volume root
# (C:\..\x is C:\x; a UNC share is a root too).  Win32 also trims trailing
# dots and spaces from a name, and what it makes of a segment such as '.. '
# or '. .' is not something to bet a containment check on: refuse those.
my sub collapse-dots(@parts, Str:D $whole --> List:D) {
	my Str @out;
	for @parts -> $p {
		next if $p eq '' || $p eq '.';
		if $p eq '..' {
			@out.pop if @out;
			next;
		}
		die "Path '$whole' has a segment of dots and spaces ('$p') that Windows "
			~ "would rename on the way in — refusing"
			if $p ~~ /^ <[.\x20]>+ $/;
		@out.push: $p.Str;
	}
	@out.List;
}

# A path split into (volume, components...): '' and ('a','b') for '/a/b';
# 'C:' and ('a','b') for 'C:\a\b'; '//srv/share' and ('x') for a UNC path.
# Only Windows treats '\' as a separator or recognises volumes — on POSIX
# both are legal filename characters.
my sub split-absolute(Str:D $abs) {
	return split-windows($abs) if $*DISTRO.is-win;
	('', |$abs.split('/').grep(*.chars));
}

# The Windows half of split-absolute, callable on any host so the reparse
# arithmetic above can be tested everywhere.  The drive letter is upcased
# so the same volume always spells the same way in comparisons.
my sub split-windows(Str:D $abs) {
	if $abs ~~ /^ [ '\\\\' | '//' ] / {
		my @comps = $abs.split(/<[\/\\]>+/).grep(*.chars);
		die "Cannot resolve a UNC path with no share name: '$abs'"
			unless @comps.elems >= 2;
		my Str $volume = '//' ~ @comps.shift ~ '/' ~ @comps.shift;
		return ($volume, |@comps);
	}
	my @comps = $abs.split(/<[\/\\]>+/);
	my Str $volume = '';
	if @comps && @comps.head ~~ /^ <[A..Za..z]> ':' $/ {
		$volume = @comps.shift.uc;
	}
	($volume, |@comps.grep(*.chars));
}

# The inverse: a volume plus components back into an IO::Path, always
# '/'-joined.  Windows accepts '/' everywhere, and emitting one spelling is
# what lets path-contains compare paths textually.
my sub join-parts(Str:D $volume, @parts --> IO::Path:D) {
	($volume ~ '/' ~ @parts.join('/')).IO;
}

#| Internal: True when $path is $root itself or lives underneath it.  Walks the
#| parent chain rather than comparing string prefixes, so /srv/root2 is never
#| mistaken for a child of /srv/root; separator spelling is unified on Windows
#| before comparing, where either slash may appear.  Comparison is exact-case:
#| on a case-insensitive filesystem a case-mismatched root can only deny
#| access, never grant it.  Total: it returns for any pair of paths (see
#| climb-limit).  Exposed with `our` scope for the containment tests — not
#| part of the public API.
our sub path-contains(IO::Path:D $root, IO::Path:D $path --> Bool:D) {
	my Int $steps = climb-limit($path);
	return False without $steps;
	my Str $root-key = path-key($root);
	my $p = $path;
	for ^$steps {
		return True if path-key($p) eq $root-key;
		my $up = $p.parent;
		last if $up.absolute eq $p.absolute;   # reached the filesystem root
		$p = $up;
	}
	False;
}

# How many steps a walk up $path's parents may take: undefined for a path
# that is not absolute, whose parents never end — the parent of '..' is
# '../..', and so on for ever, each one a longer string than the last — and
# otherwise one more than the length of its absolute spelling, since every
# step that does not stop the walk removes at least one character.  Every
# path the resolver builds is absolute; a relative one can only be made by
# applying one platform's rules to another's spelling (a Windows stand-in for
# $*DISTRO on POSIX meeting a link to 'C:\x'), and the walks refuse it rather
# than climb for ever.
my sub climb-limit(IO::Path:D $path --> Int) {
	$path.is-absolute ?? $path.absolute.chars + 1 !! Int;
}

# The comparison spelling of a path: separators unified on Windows, the
# string untouched on POSIX, where a backslash is an ordinary filename
# character.
my sub path-key(IO::Path:D $p --> Str:D) {
	$*DISTRO.is-win ?? $p.absolute.subst('\\', '/', :g) !! $p.absolute;
}

#| Path segments of $path relative to $root.  Callers join with '/' so tool
#| output reads the same on every platform.
# When the file was last written. Not IO::Path.modified: on 64-bit Windows
# MoarVM wraps its nanosecond timestamp at 32 bits, so every file lands
# within about two seconds of 1970, and elsewhere it is 37 seconds early
# (the leap seconds are never added). The floating-point stat time is right
# on every platform. Throws for a missing file, as .modified does.
my sub file-mtime(IO::Path:D $path --> Instant:D) {
	Instant.from-posix(nqp::stat_time(nqp::unbox_s($path.absolute),
		nqp::const::STAT_MODIFYTIME))
}

my sub relative-parts(IO::Path:D $root, IO::Path:D $path --> List) {
	my Int $steps = climb-limit($path);
	die "Cannot place '$path' under the root: it is not an absolute path" without $steps;
	my @parts;
	my $p = $path;
	for ^$steps {
		last if $p.absolute eq $root.absolute;
		my $up = $p.parent;
		last if $up.absolute eq $p.absolute;
		@parts.unshift: $p.basename;
		$p = $up;
	}
	@parts.List;
}

# === Helpers ===

#| Depth-first walk of everything below $dir, handing each entry and its path
#| parts relative to $dir to &visit.  Names are visited in sorted order within
#| each directory so two runs over the same tree produce the same output — the
#| grep tool truncates its results, and a truncated list that reshuffled
#| between calls would be useless.  &visit returns False to stop the walk.
#| Unreadable subdirectories are skipped rather than failing the whole walk; a
#| permission hole in one corner should not hide the rest.  Symlinked
#| directories are never descended into: that is both an escape route and a
#| way to walk in circles forever.
my sub walk-tree(IO::Path:D $dir, &visit --> Nil) {
	my sub walk(IO::Path:D $here, @rel-parts --> Bool:D) {
		my $entries = try $here.dir.List;
		return True without $entries;

		for $entries.sort(*.basename).list -> $entry {
			my @parts = (|@rel-parts, $entry.basename);
			return False unless visit($entry, @parts);
			return False if $entry.d && !$entry.l && !walk($entry, @parts);
		}
		True;
	}
	walk($dir, ());
}

#| The map tool's own walk: every file below $dir that is worth considering,
#| each as C<%( io => IO::Path, parts => path parts relative to $dir )>, plus a
#| flag saying whether the file limit cut the walk short.
#|
#| Not written in terms of walk-tree, and deliberately so.  A map has to PRUNE
#| — never descend node_modules, never descend .git — and walk-tree has no way
#| to express that: its &visit returning False aborts the entire walk, not one
#| subtree, and glob and grep depend on exactly that meaning.  The traversal
#| discipline is otherwise identical: sorted names within each directory so two
#| maps of one tree agree, unreadable directories skipped rather than fatal,
#| and symlinked directories never descended.  A symlinked FILE is checked the
#| way grep checks one — chased to its physical destination and dropped if that
#| lands outside the root — so a planted link cannot put foreign code in the map.
my sub collect-map-files(IO::Path:D $dir, IO::Path:D $root, Int:D $limit) {
	my @found;
	my Bool:D $stopped = False;

	my sub walk(IO::Path:D $here, @rel --> Nil) {
		my $entries = try $here.dir.List;
		return without $entries;

		for $entries.sort(*.basename).list -> $entry {
			last if $stopped;
			my @parts = (|@rel, $entry.basename);

			if $entry.d {
				next if $entry.l || prunable-dir($entry.basename);
				walk($entry, @parts);
				next;
			}
			next unless $entry.f;

			if $entry.l {
				my $physical = try physical-path($entry);
				next without $physical;
				next unless path-contains($root, $physical);
			}

			if @found.elems >= $limit {
				$stopped = True;
				last;
			}
			@found.push: %( io => $entry, parts => @parts.List );
		}
	}

	walk($dir, ());
	(@found.List, $stopped);
}

#| Decode bytes as UTF-8, or return an undefined Str and say why in $why.
my sub decode-text(Blob:D $bytes, Str $why is rw --> Str) {
	my $text = try $bytes.decode('utf-8');
	return $text if $text.defined;
	$why = 'it is not valid UTF-8';
	Str;
}

#| Read a file as text with no newline translation at all.  IO::Path.slurp in
#| text mode silently folds CRLF into LF and .spurt never puts it back, so a
#| file edited through it would come back with every untouched line rewritten.
#| Reading the bytes and decoding them once keeps the file's own line endings,
#| which is what "verbatim" has to mean for a tool a model edits files with.
#| Returns an undefined Str and a reason in $why when the file cannot be read
#| or is not UTF-8.
my sub slurp-text(IO::Path:D $path, Str $why is rw --> Str) {
	my $bytes = try $path.slurp(:bin);
	without $bytes {
		$why = error-line($!);
		return Str;
	}
	decode-text($bytes, $why);
}

# How much of a file the binary sniff looks at.
my constant BINARY-SNIFF-BYTES = 8192;

#| A NUL byte near the start is what every grep-alike uses to tell a binary
#| file from a text one: cheap, imperfect, and enough to keep a search of a
#| source tree from spraying object files across the answer.  Files that get
#| past it and then fail to decode are skipped on that instead.
my sub looks-binary(Blob:D $bytes --> Bool:D) {
	my Int:D $limit = min($bytes.elems, BINARY-SNIFF-BYTES);
	so (^$limit).first({ $bytes[$_] == 0 }).defined;
}

#| Recursive delete that unlinks symlinks instead of descending into them.  The
#| resolver stops a client naming anything outside the root; this stops a link
#| planted inside the root from turning "delete this directory" into a delete
#| of whatever it points at.  $rel is carried along purely so a failure names
#| the entry it failed on rather than the directory the client asked about.
my sub delete-tree(IO::Path:D $path, Str:D $rel) {
	if $path.l {
		check-io($path.unlink, "Failed to delete '$rel'");
	} elsif $path.d {
		my $entries = try $path.dir.List;
		die "Could not read directory '$rel': {error-line($!)}" without $entries;
		delete-tree($_, $rel ~ '/' ~ .basename) for $entries.list;
		check-io($path.rmdir, "Failed to delete directory '$rel'");
	} elsif $path.e {
		check-io($path.unlink, "Failed to delete '$rel'");
	}
}

my sub is-sep(Str:D $ch --> Bool:D) { $ch eq '/' || $ch eq '\\' }

#| Portable, regex-free glob matcher: '*' matches any run of characters inside
#| a single path segment, '?' matches exactly one such character, everything
#| else is literal and case-sensitive.  Building a regex from client input is
#| exactly the kind of passthrough this toolkit is meant not to have.
my sub glob-match(Str:D $pattern, Str:D $subject --> Bool:D) {
	my @p = $pattern.comb;
	my @s = $subject.comb;
	my int $pi   = 0;
	my int $si   = 0;
	my int $star = -1;
	my int $mark = 0;

	while $si < @s.elems {
		if $pi < @p.elems && @p[$pi] eq '*' {
			$star = $pi++;
			$mark = $si;
		}
		elsif $pi < @p.elems
		&& (@p[$pi] eq @s[$si] || @p[$pi] eq '?' && !is-sep(@s[$si])) {
			$pi++;
			$si++;
		}
		elsif $star >= 0 && !is-sep(@s[$mark]) {
			# Let the last '*' swallow one more character and retry.
			$pi = $star + 1;
			$si = ++$mark;
		}
		else {
			return False;
		}
	}

	$pi++ while $pi < @p.elems && @p[$pi] eq '*';
	$pi == @p.elems;
}

#| Fetch a string argument.  Handlers validate their own arguments: the MCP
#| input schema advertises what is required but nothing enforces it, and a
#| client that omits a path deserves a clearer answer than a type error.
my sub arg-str(%args, Str:D $name, Str :$default --> Str:D) {
	my $value = %args{$name};
	unless $value.defined {
		die "Missing required parameter '$name'" without $default;
		return $default;
	}
	die "Parameter '$name' must be a string, not {$value.^name}"
		if $value ~~ Positional | Associative;
	$value.Str;
}

#| Fetch a whole-number argument, optionally clamped to a range.  Without
#| :default it is required unless :optional is passed, in which case an absent
#| argument comes back as an undefined Int.  Booleans are refused explicitly:
#| Bool does Int in Raku, so a client sending `true` for a line count would
#| otherwise be silently read as the number 1.  A string of digits is accepted
#| because models produce them constantly and the intent is never in doubt.
my sub arg-int(%args, Str:D $name, Int :$default, Bool :$optional, Int :$min, Int :$max --> Int) {
	my $value = %args{$name};
	unless $value.defined {
		return $default if $default.defined;
		return Int if $optional;
		die "Missing required parameter '$name'";
	}

	die "Parameter '$name' must be a whole number, not a boolean" if $value ~~ Bool;
	my Int $int = do given $value {
		when Int          { $_ }
		when Str          { $_ ~~ /^ '-'? \d+ $/ ?? .Int !! Int }
		default           { Int }
	};
	die "Parameter '$name' must be a whole number, not {$value.^name}" without $int;

	die "Parameter '$name' must be at least $min, not $int" if $min.defined && $int < $min;
	die "Parameter '$name' must be at most $max, not $int"  if $max.defined && $int > $max;
	$int;
}

#| Fetch a flag argument.  JSON booleans arrive as Bool; the words spelled as
#| strings are accepted too, since a model that quotes `"true"` means it.
my sub arg-bool(%args, Str:D $name, Bool:D :$default = False --> Bool:D) {
	my $value = %args{$name};
	return $default without $value;
	return $value.so if $value ~~ Bool;
	if $value ~~ Str {
		return True  if $value.lc eq 'true';
		return False if $value.lc eq 'false';
	}
	die "Parameter '$name' must be true or false, not {$value.^name}";
}

my sub error-line(Mu $error --> Str:D) {
	($error.defined ?? ($error.message // '').lines.head !! Str) // 'unknown error';
}

#| Turn the unthrown Failure that IO write operations return into a thrown
#| exception with context, so the framework can report it as a tool error.
my sub check-io(Mu $result, Str:D $what) {
	return unless $result ~~ Failure;
	my $exception = $result.exception;
	$result.so;   # mark handled so it cannot resurface when it is discarded
	die "$what: {error-line($exception)}";
}

# === External searchers ===

# Why grep shells out for its candidate list.
#
# A recursive Raku scan — walk, slurp, decode, split, search, repeat — is the
# heaviest thing in this pack by allocation volume, and several of them at once
# reliably tripped a garbage-collector fault in MoarVM 2026.07 that killed the
# whole process ("Heap corruption detected: pointer ... to past fromspace").
# Nothing at the Raku level can catch that: the VM prints one line and calls
# exit().  Two independent measures fixed it at six concurrent searches, and
# this pack takes both.
#
#   * The scan is SERIALISED.  One process-wide lock — not a per-instance one,
#     because the fault is in the VM and does not care how many toolkits there
#     are — wraps the whole walk-and-read phase of every search, on every tier.
#     It is the only thing that makes the Raku tier safe.
#
#   * An external tool PICKS THE CANDIDATES.  When rg or a system grep is
#     available, it is asked which files contain the pattern, and the Raku scan
#     then only opens those.  The list arrives in one read of a pipe instead of
#     a tree's worth of decoded text, which is the allocation the collector was
#     choking on.
#
# What the external tool does NOT do is produce any of the answer.  Every byte
# the model sees is still formatted by the scan above, from files the scan
# itself opened, in the order the scan's own walk yields — so the tiers cannot
# drift apart in formatting, because there is only one formatter.  The
# candidate list is used as a FILTER over the ordinary walk and never as a
# source of paths or of order: an external searcher's idea of sorted ("a/b"
# before "a.txt") is not the walk's ("a" before "a.txt", then descend).
#
# The call to the external tool deliberately happens OUTSIDE the scan lock, so
# those stay parallel — that is the whole point of paying for a process.
#
# Three searches are never handed out, because an external tool would answer
# them differently:
#
#   * A REGEX search.  The pattern is a Raku regex, and it is only safe because
#     Rakudo refuses to interpolate one containing a code block (see the
#     comment above !grep-files).  Ripgrep would read it as Rust regex syntax
#     and system grep as POSIX — silently, and with different matches.
#
#   * A pattern that is not printable ASCII.  Raku decodes a file to NFG text
#     before searching it, so a composed "é" in the pattern matches a
#     decomposed one in the file; a byte-oriented searcher would miss it and
#     the tiers would disagree.  The reverse direction is harmless — an
#     external tool naming a file the scan then finds nothing in costs one
#     open().
#
#   * A search of a single FILE rather than a directory.  There is one
#     candidate; choosing it externally would be pure overhead.

my constant GREP-BACKEND-ENV = 'MCP_FS_GREP_BACKEND';

#| The searchers this pack knows how to drive, and the environment variable
#| that says which binary each one spawns.  The override exists for the parity
#| tests — which must be able to pin a tier to a binary they control — and for
#| the host whose ripgrep is installed under another name.
my constant SEARCHERS = Map.new((
	ripgrep => Map.new((binary => 'rg',   env => 'MCP_FS_GREP_RG_BINARY')),
	grep    => Map.new((binary => 'grep', env => 'MCP_FS_GREP_GREP_BINARY')),
));

#| Tried in this order.  Ripgrep first: it is the faster of the two and the one
#| whose flags mean the same thing on every platform it runs on.
my constant SEARCHER-ORDER = <ripgrep grep>;

# How many answers in a row that cannot be believed a searcher may give
# before it is dropped for the life of the process, as a probe that said no
# would have dropped it.  One untrusted answer costs only its own search a
# full scan, because one is as likely to be the moment (an OOM-killed child,
# an unlucky list) as the tool; five in a row, with not one believed answer
# between them, is the tool, and hundreds of searches would each pay a spawn
# for nothing.  Five rather than two or three because a searcher killed now
# and then under memory pressure must not be lost to a short bad patch;
# small, because each refusal costs a spawn and a full scan.  A believed
# answer starts the count again from nothing, and a launch that failed while
# the binary was there never counts at all.
my constant SEARCHER-UNTRUSTED-LIMIT = 5;

# Everything learned about the searchers, keyed by tool and binary, and kept
# for the life of the process unless reset-searchers clears it: the probe
# verdicts (see searcher-usable for why they are never revisited, and for the
# one outcome that is not a verdict and so is never kept), into which a search
# that finds a searcher's binary gone, or that brings its untrusted answers to
# SEARCHER-UNTRUSTED-LIMIT in a row, records the same "no"; and the count of
# those untrusted answers.  All of it behind one lock.
my $searcher-lock = Lock.new;
my %searcher-usable;
my %searcher-untrusted;
my Int $searcher-spawns = 0;
my Int $searcher-believed = 0;

#| Which tier the next literal C<grep> of a directory would use: C<'ripgrep'>,
#| C<'grep'>, or C<'raku'> when no external searcher is usable.  Probes on the
#| first call.  Exposed with `our` scope for the parity tests — not part of the
#| public API.
our sub grep-backend(--> Str:D) { chosen-searcher() || 'raku' }

#| How many external searcher processes this pack has spawned since it was
#| loaded, probes included.  The parity tests assert on it: it is the only way
#| to tell "the external tier answered" from "the external tier quietly fell
#| back and the answers matched because both came from Raku".  Exposed with
#| `our` scope for those tests — not part of the public API.
our sub grep-backend-spawns(--> Int:D) {
	$searcher-lock.protect: { $searcher-spawns }
}

#| How many of those spawns gave a candidate list this pack believed and used.
#| The spawn count alone cannot say: a searcher whose answer is not believed
#| costs that search a full scan and nothing else, so its search answers
#| exactly as the external tier would have.  Exposed with `our` scope for the
#| parity tests — not part of the public API.
our sub grep-backend-believed(--> Int:D) {
	$searcher-lock.protect: { $searcher-believed }
}

#|( Forget everything this pack has learned about the external searchers:
    every probe verdict, the "yes" and the "no" alike; every searcher dropped
    because its binary went missing or because its answers could not be
    believed SEARCHER-UNTRUSTED-LIMIT times in a row; and every count of those
    answers.  The next search that could hand its candidates out probes for a
    searcher again, from scratch, so a ripgrep installed since the first
    search is found, and one dropped in error is given its chance back.
    Process-wide, like the state it clears, which every pack instance in the
    process shares.  Safe to call while searches are running: the state is
    cleared under the lock every search takes, and a search already under way
    finishes on what it had.  Safe to call again: clearing nothing changes
    nothing.  It does not touch C<MCP_FS_GREP_BACKEND>, which is read on every
    search anyway.  Public: see "Re-checking the searchers" in the README. )
our sub reset-searchers(--> Nil) {
	$searcher-lock.protect: {
		%searcher-usable    = ();
		%searcher-untrusted = ();
	}
}

#| The first usable searcher, or '' for none.  The backend environment variable
#| pins the choice: 'ripgrep' or 'grep' to insist on one, 'raku' to insist on
#| none, 'auto' (the default) to try each in turn.  Read on every call rather
#| than cached, so a test can move a search from one tier to the next; the
#| probe behind it is what is expensive, and that is cached.
my sub chosen-searcher(--> Str:D) {
	searcher-order-for(%*ENV{GREP-BACKEND-ENV}).first({ searcher-usable($_) }) // '';
}

my sub searcher-order-for($setting --> List) {
	my Str:D $forced = ($setting // 'auto').Str.trim.lc;
	return SEARCHER-ORDER.List if $forced eq 'auto' || $forced eq '';
	return ('ripgrep',)        if $forced eq 'ripgrep' || $forced eq 'rg';
	return ('grep',)           if $forced eq 'grep';
	return ()                  if $forced eq 'raku' || $forced eq 'none';
	die "{GREP-BACKEND-ENV} must be one of auto, ripgrep, grep or raku, not '$forced'";
}

#| Has this searcher answered a C<--version>?  Asked once per binary and
#| remembered — including the "no" — because the common case for a missing tool
#| is that it will still be missing on the next call, and paying a failed spawn
#| per search would cost more than the tier saves.  A tool installed while the
#| server is running is therefore picked up at the next start, or after
#| reset-searchers, which is the intended trade.
#|
#| The one outcome that is not remembered is no answer at all: a binary that is
#| there but could not be launched, or one killed by a signal before it could
#| reply.  That is the moment failing — a process out of file descriptors, a
#| system out of processes, a binary being rewritten by an upgrade — and
#| keeping it would lose the tier for the life of the process over one bad
#| second.  So this call goes without the searcher and the next one asks again.
my sub searcher-usable(Str:D $tool --> Bool:D) {
	my Str:D $key = searcher-key($tool);
	$searcher-lock.protect: {
		if %searcher-usable{$key}:exists {
			%searcher-usable{$key};
		} else {
			my Bool $verdict = probe-searcher($tool);
			%searcher-usable{$key} = $verdict if $verdict.defined;
			$verdict // False;
		}
	}
}

#| Record that a searcher's binary is not there, as its probe would have: from
#| now on, until reset-searchers, it is not used and not spawned.
my sub drop-searcher(Str:D $tool --> Nil) {
	my Str:D $key = searcher-key($tool);
	$searcher-lock.protect: { %searcher-usable{$key} = False };
}

#| Count one answer from $tool that could not be believed, and drop the
#| searcher, as drop-searcher would, when that makes SEARCHER-UNTRUSTED-LIMIT
#| in a row.  Under the lock, so concurrent searches cannot lose a count or
#| drop it twice.
my sub count-untrusted(Str:D $tool --> Nil) {
	my Str:D $key = searcher-key($tool);
	$searcher-lock.protect: {
		%searcher-usable{$key} = False
			if ++%searcher-untrusted{$key} >= SEARCHER-UNTRUSTED-LIMIT;
	}
}

#| Count one believed answer from $tool: whatever run of untrusted answers it
#| had given is over.
my sub count-believed(Str:D $tool --> Nil) {
	my Str:D $key = searcher-key($tool);
	$searcher-lock.protect: {
		%searcher-untrusted{$key}:delete;
		$searcher-believed++;
	}
}

my sub searcher-key(Str:D $tool --> Str:D) { $tool ~ "\t" ~ searcher-binary($tool) }

my sub searcher-binary(Str:D $tool --> Str:D) {
	my $override = %*ENV{SEARCHERS{$tool}<env>};
	$override.defined && $override.Str.chars ?? $override.Str !! SEARCHERS{$tool}<binary>;
}

#| The probe: True when the searcher printed a version and exited 0; False when
#| it ran and did anything else, or when its binary is not there at all; and an
#| undefined Bool, which is no verdict, when it could not be launched although
#| its binary is there, or was killed by a signal.
my sub probe-searcher(Str:D $tool --> Bool) {
	my $run = spawn-searcher($tool, ('--version',));
	without $run {
		# run() reports "no such program" and "no descriptor left to start it
		# with" identically, as an exit code of -1.  Whether the binary is
		# there is what tells them apart.
		return searcher-findable(searcher-binary($tool)) ?? Bool !! False;
	}
	return Bool if $run<signal> != 0;
	so $run<exit> == 0 && $run<out>.elems;
}

#| Whether a spawn could have found $binary: the test that tells a searcher
#| that is not installed (a verdict, worth remembering) from one that is
#| installed and could not be launched just now (no verdict).  Generous on
#| purpose, because the two ways of being wrong are not alike: a wrong "yes"
#| costs a probe on the next call, a wrong "no" loses the tier for the life of
#| the process.  So it looks everywhere either platform's spawn might — a name
#| with a directory in it where it says, a bare name in every PATH entry (and,
#| on Windows, the working directory first), on Windows also with .com and
#| .exe appended — and accepts anything that exists there.
my sub searcher-findable(Str:D $binary --> Bool:D) {
	my Bool:D $windows = $*DISTRO.is-win;
	my @names = $windows ?? ($binary, $binary ~ '.com', $binary ~ '.exe') !! ($binary,);
	my Bool:D $placed = $binary.contains('/')
		|| ($windows && ($binary.contains('\\') || $binary.contains(':')));
	return @names.first({ .IO.e }).defined if $placed;

	# %*ENV is case-sensitive and Windows names the variable Path.
	my $key = %*ENV.keys.first({ .uc eq 'PATH' });
	my Str:D $path = $key.defined ?? %*ENV{$key}.Str !! ($windows ?? '' !! '/usr/bin:/bin');
	my @dirs = $path.split($windows ?? ';' !! ':').map({ $_ eq '' ?? '.' !! $_ });
	@dirs.unshift('.') if $windows;
	@dirs.first(-> $dir { @names.first({ $dir.IO.add($_).e }).defined }).defined;
}

#| Whether a searcher's run produced an answer that can be believed: one it
#| was not killed in the middle of, and that exited with a status its own
#| documentation calls an answer.  ripgrep's man page: 0 when something
#| matched, 1 when nothing did, 2 when an error occurred.  GNU grep's: the
#| same three.  BSD grep's, and POSIX's: 0, 1, and above 1 for an error.
#|
#| An error exit is believed when nothing was written to stderr.  Both tools
#| are run with C<--no-messages> / C<-s>, which silence exactly the messages
#| about files they could not open or read, and every one of them still exits
#| 2 for it — a root holding one unreadable file would otherwise cost every
#| search a full scan.  The list such a run prints names every file the tool
#| could read, and the scan cannot read the rest either, so it is the same
#| list a clean run would have printed.  An error that is a refusal — an
#| option it does not know, memory exhausted — is still printed, and is not
#| believed.  Checked against ripgrep 14.1.1, GNU grep 3.12 and BSD grep
#| 2.6.0: an unreadable file or directory exits 2 with the readable matches
#| listed and stderr empty; an unknown option exits 2 with nothing listed and
#| a message on stderr.  The window this leaves open is a file that opened and
#| then failed part-way through being read (EIO): that, too, is silenced and
#| believed, and a scan that could have read it would miss its lines.
#|
#| A signal is never believed, whatever the exit code says: Rakudo reports a
#| killed child as exit code 0, and the list it printed stops wherever it was
#| killed.
my sub searcher-answered(Map:D $run --> Bool:D) {
	return False if $run<signal> != 0;
	return True  if $run<exit> == 0 || $run<exit> == 1;
	$run<exit> == 2 && $run<err>.elems == 0;
}

#| The candidate list for a literal search of $dir: the set of comparison keys
#| of the files an external searcher says contain $pattern.  An undefined Set
#| means "no candidate list" — no searcher, one that could not be launched, or
#| an answer that cannot be believed — and the caller then scans everything,
#| which is always correct and only slow.
#|
#| A searcher that passed its probe and then cannot be launched is looked for
#| again, exactly as a probe that could not launch it would be.  If its binary
#| is no longer there it is dropped at once, as if its probe had said no, so
#| the searches after it go straight to the next tier and spawn nothing.  If
#| it is still there, what stopped it is the moment (out of file descriptors,
#| out of processes): the next search tries it again, and the failure is not
#| held against it.
#|
#| A searcher that was launched and gave an answer that cannot be believed
#| costs that search a full scan, and is dropped only when that has happened
#| SEARCHER-UNTRUSTED-LIMIT times in a row, because the two ways of being
#| wrong are not alike: giving up on a searcher over one bad answer — an
#| OOM-killed child, one unlucky list — would leave a long-running server on
#| the slow tier for the rest of its life, while keeping one that never
#| answers properly costs a spawn per search, which a short run of them can
#| afford and hundreds cannot.
my sub external-candidates(Str:D $pattern, IO::Path:D $dir --> Set) {
	my Str:D $tool = chosen-searcher();
	return Set unless $tool;

	my $run = spawn-searcher($tool, searcher-args($tool, $pattern, $dir.absolute));
	without $run {
		drop-searcher($tool) unless searcher-findable(searcher-binary($tool));
		return Set;
	}
	unless searcher-answered($run) {
		count-untrusted($tool);
		return Set;
	}

	my @paths = $run<out>.decode('utf8-c8').lines.grep(*.chars);
	# We hand the searcher an absolute directory, so every path it names must
	# come back absolute.  One that does not means we are not driving what we
	# think we are driving, and a candidate list we cannot align with the walk
	# would silently hide matches.
	if @paths.first({ !.IO.is-absolute }).defined {
		count-untrusted($tool);
		return Set;
	}
	count-believed($tool);
	@paths.map({ search-key($_) }).Set;
}

#| The argument list for one candidate query.  Every flag is here to make the
#| searcher's idea of "which files are worth opening" a SUPERSET of the scan's:
#| it may name a file the scan then rejects, but it must never stay silent
#| about one the scan would have matched.
my sub searcher-args(Str:D $tool, Str:D $pattern, Str:D $dir --> List) {
	return (
		'--files-with-matches',   # the list, not the lines: the scan reads the lines
		'--no-config',            # a user's rg config file must not change what we see
		'--no-ignore',            # .gitignore is not this pack's filter; the root is
		'--hidden',               # the walk does not skip dotfiles, so neither may this
		'--no-follow',            # nor does the walk descend a symlinked directory
		'--no-messages',          # an unreadable file is the walk's business
		'--text',                 # and a binary one is the scan's: it must be listed
		'--fixed-strings',        # literal, always: a regex never reaches this tier
		'--', $pattern, $dir,
	) if $tool eq 'ripgrep';

	# The same seven decisions in the flags BSD grep and GNU grep agree on:
	# -r recurses without following links found on the way, -l lists names,
	# -F is literal, -a stops binary files being dropped, -s silences the
	# unreadable ones.  Neither reads a config file, and neither has an
	# ignore-file notion to turn off.
	return ('-r', '-l', '-F', '-a', '-s', '--', $pattern, $dir) if $tool eq 'grep';

	();
}

#| Run a searcher, and say what it did: a Map of its C<exit> code, the
#| C<signal> that killed it (0 for none), and its C<out> and C<err> bytes.  Nil
#| when it could not be launched at all.  Never throws: a search that cannot
#| shell out is a search that scans everything instead.
#|
#| C<run> rather than C<Proc::Async> deliberately.  On Rakudo 2026.07 a
#| C<Proc::Async> whose binary does not exist breaks an unhandled promise on a
#| scheduler thread and takes the process down with it, C<try> or no C<try>;
#| C<run> reports the same condition as an exit code of -1, and reports a
#| spawn refused for want of file descriptors the same way.  stderr is drained
#| on its own thread because a child that fills its stderr pipe while we are
#| reading its stdout deadlocks both of us.  And its stdin is B<closed> rather
#| than inherited: this pack's usual home is a server speaking JSON-RPC over
#| stdin, and a child that read one byte of that would eat the conversation.
my sub spawn-searcher(Str:D $tool, @arguments --> Map) {
	$searcher-lock.protect: { $searcher-spawns++ };

	my $proc = try run(
		searcher-binary($tool), |@arguments,
		:in(False), :out, :err, :bin, :env(searcher-env()),
	);
	return Nil without $proc;

	my $draining = start { (try $proc.err.slurp(:close)) // Buf.new };
	my $out      = (try $proc.out.slurp(:close)) // Buf.new;
	my $err      = await $draining;

	my $exit = try $proc.exitcode;
	return Nil unless $exit.defined && $exit >= 0;
	my $signal = (try $proc.signal) // 0;
	Map.new((exit => $exit, signal => $signal, out => $out, err => $err));
}

#| The environment a searcher runs in: ours, minus everything that could talk
#| it into searching differently, plus the C locale so a literal search is a
#| byte search whatever the host is set to.
my sub searcher-env(--> Hash) {
	my %env = %*ENV;
	%env<GREP_OPTIONS GREP_COLOR GREP_COLORS RIPGREP_CONFIG_PATH>:delete;
	%env<LC_ALL> = 'C';
	%env;
}

#| True when a literal pattern means the same thing to an external searcher as
#| it does to the Raku scan: printable ASCII, plus tab.  Anything else — a
#| composed character that normalisation could move, a newline that a searcher
#| would read as a second pattern, a NUL that C<argv> cannot carry — goes to
#| the Raku tier instead of to a guess.
my sub externally-searchable(Str:D $pattern --> Bool:D) {
	!$pattern.ords.first({ $_ != 0x09 && ($_ < 0x20 || $_ > 0x7E) }).defined;
}

#| True when an external searcher's silence about a file cannot be believed,
#| whatever it said about the rest of the tree, so the scan must open it.  Two
#| kinds: a symlink, which neither ripgrep nor either grep follows when it
#| finds one during a traversal, while this pack's scan reads one whose target
#| is inside the root; and a name carrying a line break, which cannot be found
#| in a list that arrives one path per line.
my sub unreportable-file(IO::Path:D $file --> Bool:D) {
	return True if $file.l;
	my Str:D $absolute = $file.absolute;
	$absolute.contains("\n") || $absolute.contains("\r");
}

#| The spelling a path is compared by when matching a searcher's output against
#| the walk's: repeated and trailing separators collapsed, Windows separators
#| and drive letter unified, so C<//srv//x> and C</srv/x> are one file.
my sub search-key(Str:D $absolute --> Str:D) {
	my ($volume, @parts) = split-absolute($absolute);
	path-key(join-parts($volume, @parts));
}
