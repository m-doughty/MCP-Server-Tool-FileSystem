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
			~ 'text are skipped and counted, and the search stops once max-results '
			~ 'lines have matched.',
		params => {
			pattern => {
				type        => 'string',
				description => 'Text to search for, or a Raku regex when regex is true',
				required    => True,
			},
			path => {
				type        => 'string',
				description => 'File to search, or directory to search below, relative to the root; defaults to the root itself',
			},
			regex => {
				type        => 'boolean',
				description => 'Treat pattern as a Raku regex instead of literal text; defaults to false',
			},
			glob => {
				type        => 'string',
				description => 'Only search files whose name matches this wildcard, e.g. "*.raku"; may not contain "/"',
			},
			'context' => {
				type        => 'integer',
				description => 'Lines of surrounding context to show around each match, 0 to 20; defaults to 0',
			},
			'max-results' => {
				type        => 'integer',
				description => 'Stop after this many matching lines, 1 to 1000; defaults to 50',
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
			},
			query => {
				type        => 'string',
				description => 'Space-separated identifiers or words to focus the map on; matching files and symbols rank higher',
			},
			focus => {
				type        => 'string',
				description => 'Space- or comma-separated file paths, relative to the root, to weight heavily',
			},
			'max-chars' => {
				type        => 'integer',
				description => 'Upper bound on the size of the map in characters, 512 to 65536; defaults to 8192',
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

	my @base = relative-parts($!root, $target);
	my @out;
	my Int:D $matched = 0;
	my Int:D $skipped = 0;

	# Returns False once the result budget is spent, which stops the walk.
	my sub scan(IO::Path:D $file, Str:D $display --> Bool:D) {
		return True unless $file.f;
		return True if $glob ne '' && !glob-match($glob, $file.basename);
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
		if looks-binary($bytes) {
			$skipped++;
			return True;
		}
		my Str $why;
		my $text = decode-text($bytes, $why);
		without $text {
			$skipped++;
			return True;
		}

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

	if $target.d {
		walk-tree($target, -> $entry, @parts { scan($entry, (|@base, |@parts).join('/')) });
	} else {
		scan($target, @base.join('/'));
	}

	my @notices;
	if $matched >= $max {
		my Str:D $lines = $max == 1 ?? 'line' !! 'lines';
		@notices.push: "[stopped at $max matching $lines; raise max-results to see more]";
	}
	if $skipped {
		my Str:D $files = $skipped == 1 ?? 'file that is not' !! 'files that are not';
		@notices.push: "[skipped $skipped $files UTF-8 text]";
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
			my $mtime = (try $entry.modified) // Instant;
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

	my $modified = try $path.modified;
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
# platform so behaviour (and the test suite) is identical everywhere.
my constant RESERVED-SEGMENTS = set flat
	<con prn aux nul>,
	(1 .. 9).map({ "com$_" }),
	(1 .. 9).map({ "lpt$_" });

#| Turn a client-supplied relative path into an IO::Path under $.root, or die.
#| Three layers, deliberately redundant: textual rejection of anything that
#| could be absolute, a ban on ".." segments, and a physical-path check that
#| chases every symlink itself and catches links pointing out of the sandbox.
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
		if @parts.first({ RESERVED-SEGMENTS{.split('.').head.lc} }).defined;

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
    component, the way realpath does it.  Exists because IO::Path.resolve is
    documented not to follow symlinks on Windows, and a containment check is
    only as good as the resolution it checks.  Fails closed: dies when a link
    target cannot be read, when a chain exceeds :max-hops (a cycle, in
    practice), or when a Windows link uses a drive-relative target.  Exposed
    with `our` scope for the containment tests — not part of the public API. )
our sub physical-path(IO::Path:D $path, Int:D :$max-hops = 40 --> IO::Path:D) {
	my ($volume, @todo) = split-absolute($path.absolute);
	my Str @out;
	my Int $hops = 0;

	while @todo {
		my Str $part = @todo.shift.Str;
		next if $part eq '' || $part eq '.';
		if $part eq '..' {
			# The chased prefix is link-free, so popping a component is what
			# the filesystem itself would do — this is what makes a link to
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
			# Windows link targets can restart the walk at a new volume (UNC
			# or drive-rooted), at the current volume's root (separator-
			# rooted), or continue relative to the link's directory.  A
			# drive-relative target ('C:foo') depends on a per-drive working
			# directory this process does not track: refuse it.
			if $target ~~ /^ [ '\\\\' | '//' ] /
			|| $target ~~ /^ <[A..Za..z]> ':' <[\/\\]> / {
				my ($v, @tc) = split-absolute($target);
				$volume = $v;
				@out = ();
				@todo.prepend: @tc;
				next;
			}
			die "Symlink at '$cur' has a drive-relative target '$target' — refusing"
				if $target ~~ /^ <[A..Za..z]> ':' /;
			@out = () if $target ~~ /^ <[\/\\]> /;
			@todo.prepend: $target.split(/<[\/\\]>+/).grep(*.chars);
			next;
		}

		# POSIX: only '/' separates and only a leading '/' restarts the walk.
		# A backslash is an ordinary filename character here.
		@out = () if $target.starts-with('/');
		@todo.prepend: $target.split('/').grep(*.chars);
	}

	join-parts($volume, @out);
}

# A path split into (volume, components...): '' and ('a','b') for '/a/b';
# 'C:' and ('a','b') for 'C:\a\b'; '//srv/share' and ('x') for a UNC path.
# Only Windows treats '\' as a separator or recognises volumes — on POSIX
# both are legal filename characters.  The drive letter is upcased so the
# same volume always spells the same way in comparisons.
my sub split-absolute(Str:D $abs) {
	if $*DISTRO.is-win {
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
		return ($volume, |@comps.grep(*.chars));
	}
	('', |$abs.split('/').grep(*.chars));
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
#| access, never grant it.  Exposed with `our` scope for the containment
#| tests — not part of the public API.
our sub path-contains(IO::Path:D $root, IO::Path:D $path --> Bool:D) {
	my Str $root-key = path-key($root);
	my $p = $path;
	loop {
		return True if path-key($p) eq $root-key;
		my $up = $p.parent;
		last if $up.absolute eq $p.absolute;   # reached the filesystem root
		$p = $up;
	}
	False;
}

# The comparison spelling of a path: separators unified on Windows, the
# string untouched on POSIX, where a backslash is an ordinary filename
# character.
my sub path-key(IO::Path:D $p --> Str:D) {
	$*DISTRO.is-win ?? $p.absolute.subst('\\', '/', :g) !! $p.absolute;
}

#| Path segments of $path relative to $root.  Callers join with '/' so tool
#| output reads the same on every platform.
my sub relative-parts(IO::Path:D $root, IO::Path:D $path --> List) {
	my @parts;
	my $p = $path;
	loop {
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
