use TreeSitter::Native;
use TreeSitter::Native::Languages;
use TreeSitter::Native::Query;

#| The parsing, ranking and rendering behind the map tool.  Kept out of
#| MCP::Server::Tool::FileSystem because none of it touches the filesystem or
#| the MCP layer: everything here takes bytes and gives back facts, which is
#| also what makes it testable without a server.
#|
#| The shape of a repo map is Aider's: for every file, the lines that DEFINE
#| something, ranked by how much the rest of the tree refers to those
#| definitions.  Bodies never appear.  A model reads one map instead of twenty
#| files and then knows which twenty files it did not need.
unit module MCP::Server::Tool::FileSystem::Map;

# === Limits ===

#| How many files one map will look at before it stops walking.  A map of a
#| tree this big is already past the point of being readable; the valve exists
#| so pointing the tool at a home directory costs seconds rather than minutes.
our constant MAP-FILE-LIMIT is export = 5000;

#| Files larger than this are skipped and counted.  Generated bundles and
#| vendored blobs are what actually trips it, and neither belongs in a map.
our constant MAP-MAX-FILE-BYTES is export = 1024 * 1024;

# How much of a definition line is worth keeping.  Long enough for a Java
# method signature, short enough that one minified line cannot eat the budget.
my constant DEF-LINE-CHARS = 160;

# Definitions per file in the first rendering pass, before the budget has had
# its say.  Aider uses the same order of magnitude.
my constant DEFS-PER-FILE = 20;

# How many files may define one identifier before it stops meaning anything.
# Its edges and its definitions are discounted rather than dropped: a repo
# where every file defines `new` should still rank the file everything calls
# `new` on.
my constant COMMON-DEFINER-LIMIT = 5;

# What share of a map's files may refer to one name before that name stops
# identifying anything in it.  Half is a wide margin rather than a fine
# judgement: measured over a 131-file application, `new` was referred to by
# 75% of them and the next most widespread name by 41%, with every symbol
# anyone would want to read below that.
my constant COMMON-REFERRER-SHARE = 0.5;

# ...and how many files a map needs before that share is evidence of anything.
# In a map of three files, "referred to by most of them" is what a well-named
# central symbol looks like.
my constant BREADTH-SAMPLE-FLOOR = 8;

# === Language table ===

# Extension to grammar.  '.h' goes to cpp rather than c on purpose: the C++
# grammar is a superset, so a C header still parses, and a C++ header full of
# methods does not silently lose them.  The cost is an exotic K&R header
# parsing oddly, which loses a definition rather than producing a wrong one.
my constant %EXT-LANGUAGE = %(
	'c'       => 'c',
	'h'       => 'cpp',
	'cc'      => 'cpp',
	'cpp'     => 'cpp',
	'cxx'     => 'cpp',
	'hpp'     => 'cpp',
	'hh'      => 'cpp',
	'hxx'     => 'cpp',
	'go'      => 'go',
	'java'    => 'java',
	'js'      => 'javascript',
	'jsx'     => 'javascript',
	'mjs'     => 'javascript',
	'cjs'     => 'javascript',
	'py'      => 'python',
	'pyi'     => 'python',
	'rs'      => 'rust',
	'tsx'     => 'tsx',
	'ts'      => 'typescript',
	'mts'     => 'typescript',
	'cts'     => 'typescript',
	# No tree-sitter grammar exists for Raku, so it gets the heuristic
	# scanner below rather than being left off the map of its own toolkit.
	'raku'    => 'raku',
	'rakumod' => 'raku',
	'rakutest'=> 'raku',
	'pm6'     => 'raku',
	'p6'      => 'raku',
);

#| The grammar name for a file, or an undefined C<Str> when the map has no way
#| to read it.  Matched on the extension alone: content sniffing would cost a
#| read of every file in the tree to place the handful the table misses.
sub lang-for(Str:D $basename --> Str) is export {
	my Int:D $dot = $basename.rindex('.') // -1;
	return Str if $dot < 1 || $dot == $basename.chars - 1;
	%EXT-LANGUAGE{$basename.substr($dot + 1).lc} // Str;
}

# Directories that are never source: caches, build output, dependency trees.
# Mapping them is not merely wasted budget — a vendored copy of a library
# outranks the code that uses it, because everything refers to it.
my constant PRUNED-DIRS = set <
	.git .hg .svn .precomp .build build node_modules target dist vendor
	__pycache__ .venv venv
>;

#| True for a directory basename the map walk should not descend into.  Every
#| dot-directory is pruned, not just the listed ones: they are configuration
#| and state by convention, and a map of C<.cache> helps nobody.
sub prunable-dir(Str:D $name --> Bool:D) is export {
	return True if PRUNED-DIRS{$name};
	so $name.starts-with('.');
}

# === Supplemental queries ===

# The vendored tags.scm files are uneven, and unevenly in the same direction:
# they were written for a symbol index, not for a call graph.
#
#   c, cpp     tag definitions but not a single reference, so a C tree would
#              rank as a heap of unrelated files.
#   typescript,
#   tsx        tag only SIGNATURES — the declare/abstract/interface forms —
#              plus class and type references.  An ordinary TypeScript file,
#              where every function has a body, would contribute neither
#              definitions nor call edges: nearly the whole language.
#
# These queries fill both gaps.  They are written from the grammars' own node
# types, NOT copied or adapted from any other project's query files, and they
# capture under the same @definition.* / @reference.* names the vendored
# queries use, so the parser below needs no special case and duplicates
# between the two queries collapse on their own.
#
# Compiled :lenient, and behind a try: a grammar bump that renames a node type
# costs this language its supplemental tags, never the tool call.

my constant C-REFS-SCM = q:to/SCM/;
	(call_expression function: (identifier) @name) @reference.call
	(call_expression
		function: (field_expression field: (field_identifier) @name)) @reference.call
	SCM

my constant CPP-REFS-SCM = q:to/SCM/;
	(call_expression function: (identifier) @name) @reference.call
	(call_expression
		function: (field_expression field: (field_identifier) @name)) @reference.call
	(call_expression
		function: (qualified_identifier name: (identifier) @name)) @reference.call
	(call_expression
		function: (template_function name: (identifier) @name)) @reference.call
	SCM

my constant TS-EXTRA-SCM = q:to/SCM/;
	(function_declaration name: (identifier) @name) @definition.function
	(generator_function_declaration name: (identifier) @name) @definition.function
	(class_declaration name: (type_identifier) @name) @definition.class
	(method_definition name: (property_identifier) @name) @definition.method
	(enum_declaration name: (identifier) @name) @definition.type
	(type_alias_declaration name: (type_identifier) @name) @definition.type
	(variable_declarator
		name: (identifier) @name value: (arrow_function)) @definition.function
	(variable_declarator
		name: (identifier) @name value: (function_expression)) @definition.function
	(call_expression function: (identifier) @name) @reference.call
	(call_expression
		function: (member_expression property: (property_identifier) @name)) @reference.call
	SCM

my constant %SUPPLEMENTAL = %(
	'c'          => C-REFS-SCM,
	'cpp'        => CPP-REFS-SCM,
	'typescript' => TS-EXTRA-SCM,
	'tsx'        => TS-EXTRA-SCM,
);

# === Observability ===

#| How many files have been read and extracted since the process started, as
#| opposed to answered from the caller's cache.  Exists so a test can prove
#| the cache works without timing anything, which is the only way to assert it
#| that does not go flaky on a loaded machine.
our $PARSE-COUNT is export = 0;

# === Scanner ===

#| The parsers and compiled queries for one map call.
#|
#| Compiling a tags.scm is the expensive part of tree-sitter — hundreds of
#| patterns — so it must not happen per file.  It is also the part with native
#| handles behind it, so it must not outlive the call that made it either: one
#| Scanner is built per map, used for every file in that map, and disposed at
#| the end.  Languages are built on first use, so mapping a pure-Raku tree
#| never loads a grammar at all.
#|
#|     my $scanner = Scanner.new;
#|     LEAVE $scanner.dispose;
#|     my %tags = extract-tags($bytes, 'python', $scanner);
class Scanner is export {
	has %!parsers;
	has %!tag-queries;
	has %!extra-queries;
	# Languages whose grammar or query would not load.  Recorded so a broken
	# grammar costs one failed attempt per map rather than one per file.
	has %!broken;

	#| The parser for C<$lang>, or the C<Parser> type object when the grammar
	#| will not load.
	method parser(Str:D $lang --> Parser) {
		return Parser if %!broken{"parser:$lang"};
		return %!parsers{$lang} if %!parsers{$lang}:exists;
		my $parser = try Parser.new($lang);
		unless $parser.defined {
			%!broken{"parser:$lang"} = True;
			return Parser;
		}
		%!parsers{$lang} = $parser;
	}

	#| The compiled tags query for C<$lang>, or the C<Query> type object.
	method tag-query(Str:D $lang --> Query) {
		self!query(%!tag-queries, 'tags', $lang, { tags-query($lang) });
	}

	#| The compiled supplemental query for C<$lang>, or the C<Query> type
	#| object when that language does not need one.
	method extra-query(Str:D $lang --> Query) {
		my $scm = %SUPPLEMENTAL{$lang};
		return Query without $scm;
		self!query(%!extra-queries, 'extra', $lang, { $scm });
	}

	method !query(%cache, Str:D $kind, Str:D $lang, &source --> Query) {
		return Query if %!broken{"$kind:$lang"};
		return %cache{$lang} if %cache{$lang}:exists;
		# :lenient throughout — an unknown predicate in a vendored query is
		# a reason to return slightly coarser matches, never a reason for
		# the whole tool to fail.
		my $query = try Query.new($lang, source(), :lenient);
		unless $query.defined {
			%!broken{"$kind:$lang"} = True;
			return Query;
		}
		%cache{$lang} = $query;
	}

	#| Free every native handle this Scanner built.  Idempotent.
	method dispose(--> Nil) {
		.dispose for %!tag-queries.values;
		.dispose for %!extra-queries.values;
		.dispose for %!parsers.values;
		%!tag-queries = ();
		%!extra-queries = ();
		%!parsers     = ();
	}
}

# === Extraction ===

#| Everything the map knows about one file: the definitions it makes, and a
#| Bag of every identifier it mentions.
#|
#|     %( defs => [ %( name => 'frobnicate', line => 12, text => 'sub frobnicate($x) {' ), … ],
#|        refs => bag('frobnicate', 'Hub', 'Hub') )
#|
#| Both halves are self-contained on purpose: the graph builder never reopens
#| a file, so a cached result stays useful when its neighbours change.
#|
#| Returns the C<Hash> type object when the file cannot be read at all — a
#| Raku source file that is not valid UTF-8, in practice.  Callers count that
#| as skipped.
sub extract-tags(Blob:D $bytes, Str:D $lang, Scanner:D $scanner --> Hash) is export {
	$PARSE-COUNT++;
	return %( defs => [], refs => bag() ) unless $bytes.elems;
	return raku-tags($bytes) if $lang eq 'raku';
	tree-tags($bytes, $lang, $scanner);
}

# --- tree-sitter path ---

my sub tree-tags(Blob:D $bytes, Str:D $lang, Scanner:D $scanner --> Hash) {
	my $parser = $scanner.parser($lang);
	return %( defs => [], refs => bag() ) without $parser;

	my $tree = try $parser.parse-bytes($bytes);
	return %( defs => [], refs => bag() ) without $tree;

	my @defs;
	my @refs;
	{
		# First statement in the block, so the phaser is always reached
		# before anything below it can throw.
		LEAVE $tree.dispose;
		my $root = $tree.root-node;
		for ($scanner.tag-query($lang), $scanner.extra-query($lang)) -> $query {
			next without $query;
			# Consumed to exhaustion, always: an abandoned lazy Seq leaves
			# its native cursor to the garbage collector, and a map walks
			# thousands of files before the collector is likely to run.
			for $query.matches($root) -> $match {
				my ($kind, $name) = classify-match($match);
				next without $kind;
				next without $name;
				my Str:D $text = node-text($name);
				next unless $text.chars;
				if $kind eq 'def' {
					@defs.push: %(
						name => $text,
						line => $name.start-point.row + 1,
						text => trim-def(line-at-byte($bytes, $name.start-byte)),
					);
				} else {
					@refs.push: $text;
				}
			}
		}
	}

	%( defs => tidy-defs(@defs), refs => @refs.Bag );
}

# One match, reduced to what a map cares about: whether it is a definition or
# a reference, and the node naming it.  Matched on the capture-name PREFIX
# rather than the full set of names, so a grammar that adds
# @definition.trait or @reference.macro next year is understood without a
# change here, and @doc / @local.scope are ignored without being enumerated.
my sub classify-match($match) {
	my Str $kind;
	my $name;
	for $match.entries -> $pair {
		my Str:D $key = $pair.key;
		if !$kind.defined && $key.starts-with('definition.') {
			$kind = 'def';
		}
		elsif !$kind.defined && $key.starts-with('reference.') {
			$kind = 'ref';
		}
		elsif $key eq 'name' && !$name.defined {
			$name = $pair.value;
		}
	}
	($kind, $name);
}

# Node text, without letting one undecodable identifier kill a whole file.
# latin-1 always decodes, so the fallback produces a stable — if mangled —
# key that still matches itself across files, which is all the graph needs.
my sub node-text($node --> Str:D) {
	my $text = try $node.text;
	return $text if $text.defined;
	my $slice = try $node.byte-slice;
	return '' without $slice;
	$slice.decode('latin-1');
}

# --- Raku path ---

# Identifier characters as Raku spells them: a hyphen or apostrophe is part of
# the name only when a letter follows it, so `x-1` is `x` and `don't-stop` is
# one identifier.
my regex rname { <[A..Za..z_]> [ <[A..Za..z0..9_]> | <[\-']> <?before <[A..Za..z_]>> ]* }
my regex pkgname { <rname> [ '::' <rname> ]* }

# The same thing as <pkgname>, written flat.  It exists because this one runs
# over every byte of every Raku file in the tree, and a subrule call per
# character costs twice what the inlined form does — measured, not guessed.
# Keep the two in step: a change to rname belongs here too.
my regex refname {
	<[A..Za..z_]>
	[ <[A..Za..z0..9_]> | <[\-']> <?before <[A..Za..z_]>> | '::' <?before <[A..Za..z_]>> ]*
}

# The declarators that can precede a definition without changing what it is.
my regex declprefix {
	[ [ 'my' | 'our' | 'has' | 'unit' | 'multi' | 'proto' | 'only' | 'augment' ] \s+ ]*
}

# Every declaration form in one pattern rather than six.  This runs on every
# line of every Raku file in the tree, and six regex engine entries per line
# is the difference between a map that costs a second and one that costs a
# minute.  It is anchored, so a line that declares nothing — almost all of
# them — fails within a few characters.
my regex rakudef {
	^ \s* <declprefix>
	[
		[ 'sub' | 'method' | 'submethod' ] \s+ '!'? $<name> = <rname>
		| [ 'class' | 'role' | 'grammar' | 'module' | 'package' ] \s+ $<name> = <pkgname>
		| [ 'token' | 'rule' | 'regex' ] \s+ $<name> = <rname>
		| 'constant' \s+ <[$@%&]>? $<name> = <rname>
		| 'enum' \s+ $<name> = <pkgname>
	]
}

# The brackets a declarator doc block can be opened with.
my constant %DOC-BRACKETS = %( '(' => ')', '{' => '}', '[' => ']' );

# A Raku source file, read the way a careful human skim reads one.  There is
# no tree-sitter grammar for Raku — there is barely a grammar for Raku that is
# not Rakudo itself — so this is deliberately a heuristic: it never dies, it
# never runs any of the code it reads, and it misses declarations spelled in
# ways no one spells them.  What it does get right is every declaration form
# that appears in this distribution and its neighbours, which is the point.
my sub raku-tags(Blob:D $bytes --> Hash) {
	my $text = try $bytes.decode('utf-8');
	return Hash without $text;

	my @lines = $text.lines;
	my @defs;
	my Str @code;        # every line that is neither comment nor Pod
	my Str $pod-end;     # the =end tag currently being waited for
	my Bool:D $pod = False;
	my Str $doc-open;    # the bracket a declarator block was opened with
	my Str $doc-close;
	my Int:D $doc-depth = 0;

	for ^@lines.elems -> $index {
		my Str:D $raw = @lines[$index];

		# Inside a bracketed declarator block.  Its continuation lines carry
		# no '#' at all, so anything that looked for one would read prose as
		# code — and prose about code is full of the words `sub`, `class` and
		# `constant`, which is exactly how a sentence becomes a definition.
		if $doc-depth > 0 {
			$doc-depth = bracket-depth($raw, $doc-open, $doc-close, $doc-depth);
			next;
		}

		# Pod is documentation, and documentation is full of the words the
		# ranking is trying to weigh.  Skipped entirely, both forms: the
		# delimited =begin/=end block and the abbreviated directive that
		# runs to the next blank line.
		if $pod {
			if $pod-end.defined {
				$pod = False if $raw.trim eq $pod-end;
			} elsif $raw.trim eq '' {
				$pod = False;
			}
			next;
		}
		if $raw ~~ /^ '=' <[A..Za..z]> / {
			$pod = True;
			$pod-end = $raw ~~ /^ '=begin' \s+ $<tag> = [\S+] /
				?? '=end ' ~ $/<tag>
				!! Str;
			# An =end with no =begin, and one-line directives, both stop
			# here rather than swallowing the rest of the file.
			$pod = False if $raw ~~ /^ '=end' » /;
			next;
		}

		my Int:D $cut = comment-start($raw);
		my Str:D $line = $cut >= 0 ?? $raw.substr(0, $cut) !! $raw;

		# `#|( … )` and `#=( … )` — a declarator doc block, which runs until
		# its bracket closes however many lines later.  Detected from the
		# comment wherever it starts, because the trailing form (`has $.x;
		# #=( … )`) is as legal as the leading one; the code before it on
		# this line is still code and is still read as such.
		if $cut >= 0
		&& $raw.substr($cut) ~~ /^ '#' <[|=]> $<open> = [ '(' | '{' | '[' ] / {
			$doc-open  = ~$/<open>;
			$doc-close = %DOC-BRACKETS{$doc-open};
			$doc-depth = bracket-depth($raw.substr($cut + $/.to), $doc-open, $doc-close, 1);
		}

		if $line ~~ &rakudef {
			@defs.push: %(
				name => ~$/<name>,
				line => $index + 1,
				text => trim-def($raw),
			);
		}
		@code.push: $line;
	}

	# Every identifier in the file is a candidate reference.  Names that
	# nothing defines are dropped when the graph is built, so casting wide
	# here costs memory rather than accuracy — and it is what lets
	# `use Foo::Bar` and a bare `Foo::Bar.new` produce the same edge.
	#
	# One pass over the whole file rather than one per line: entering the
	# regex engine is the expensive part, and a thousand entries per file is
	# what turns mapping a Raku tree from seconds into minutes.
	%( defs => tidy-defs(@defs), refs => @code.join("\n").comb(&refname).Bag );
}

#|( How much of a declarator block is still open after this line, given that
    C<$start> of it was open before.  Deliberately approximate: brackets are
    counted as characters, with no attention to quoting, escapes or the
    difference between prose and code.  Raku's own parser counts the same
    brackets, so a doc block whose text carries an unmatched one is already
    a file that does not compile — but if one turns up anyway, the worst that
    happens is that the rest of the file is read as documentation, which
    costs definitions rather than inventing them.  The block this comment
    lives in is itself the case being handled. )
my sub bracket-depth(Str:D $text, Str:D $open, Str:D $close, Int:D $start --> Int:D) {
	max(0, $start + $text.indices($open).elems - $text.indices($close).elems);
}

# The index of the first '#' that starts a comment, or -1 when the line has
# none.  A full lexer is not on the table here, so this tracks single and
# double quotes and treats an apostrophe inside a word as part of the word —
# which is exactly what Raku does with `don't-stop` — and gets the remaining
# cases wrong in the harmless direction: a missed comment contributes a few
# identifiers nobody defines.
my sub comment-start(Str:D $line --> Int:D) {
	# The overwhelmingly common case, and the only one worth optimising:
	# there is no '#' anywhere, so there is nothing to scan for.
	return -1 unless $line.contains('#');
	my @c = $line.comb;
	my Str $quote;
	my Int:D $cut = -1;
	for ^@c.elems -> $i {
		next if $cut >= 0;
		my Str:D $ch = @c[$i];
		if $quote.defined {
			$quote = Str if $ch eq $quote && ($i == 0 || @c[$i - 1] ne '\\');
		}
		elsif $ch eq '"' || ($ch eq "'" && ($i == 0 || !word-char(@c[$i - 1]))) {
			$quote = $ch;
		}
		elsif $ch eq '#' {
			$cut = $i;
		}
	}
	$cut;
}

# Whether a character can appear inside an identifier, asked once per
# character of every commented line — which is why it is ord arithmetic and
# not a regex.  ASCII is the whole question here: the only thing it decides is
# whether an apostrophe is opening a string or sitting inside `don't-stop`.
my sub word-char(Str:D $ch --> Bool:D) {
	my int $o = $ch.ord;
	$o >= 97 && $o <= 122 || $o >= 65 && $o <= 90
		|| $o >= 48 && $o <= 57 || $o == 95;
}

# --- shared ---

# How far either side of a definition the search for its line's ends will go.
# A minified bundle is one line a megabyte long with a thousand definitions in
# it; without a bound, each of them would walk the whole file.  Comfortably
# more bytes than DEF-LINE-CHARS characters can need, so an ordinary line is
# never affected.
my constant MAX-DEF-LINE-BYTES = 4096;

# One source line, found by byte offset rather than by counting graphemes:
# tree-sitter's offsets are byte offsets, and a Raku string index is not one.
# CRLF makes the difference visible — "\r\n" is a single grapheme with two
# bytes in it — so the arithmetic stays on the Blob and the decode happens
# once, on the line that came out.
my sub line-at-byte(Blob:D $bytes, Int:D $offset --> Str:D) {
	my Int:D $n = $bytes.elems;
	return '' unless $n;
	my Int:D $at = min(max(0, $offset), $n - 1);
	my Int:D $floor = max(0, $at - MAX-DEF-LINE-BYTES);
	my Int:D $ceiling = min($n, $at + MAX-DEF-LINE-BYTES);
	my Int $start = $at;
	$start-- while $start > $floor && $bytes[$start - 1] != 0x0A;
	my Int $end = $at;
	$end++ while $end < $ceiling && $bytes[$end] != 0x0A;
	my $slice = $bytes.subbuf($start, $end - $start);
	((try $slice.decode('utf-8')) // $slice.decode('latin-1'));
}

my sub trim-def(Str:D $text --> Str:D) {
	my Str:D $trimmed = $text.trim;
	$trimmed.chars > DEF-LINE-CHARS
		?? $trimmed.substr(0, DEF-LINE-CHARS - 3) ~ '...'
		!! $trimmed;
}

# Definitions, deduplicated and put in a fixed order.  Two query patterns can
# tag the same node — a C++ struct is both a class and a type — and a map that
# listed it twice would be paying twice for it.
my sub tidy-defs(@defs --> Array) {
	my %seen;
	my @out;
	for @defs -> %def {
		my Str:D $key = %def<line> ~ ':' ~ %def<name>;
		next if %seen{$key};
		%seen{$key} = True;
		@out.push: %def;
	}
	@out.sort({ $^a<line> <=> $^b<line> || $^a<name> leg $^b<name> }).Array;
}

# === Ranking ===

my constant DAMPING = 0.85;
my constant MAX-ITERATIONS = 30;
my constant CONVERGENCE = 1e-6;

# Weight multipliers for the personalization vector.  Both are large enough to
# reorder the map decisively — a query that only nudged the ranking would be
# indistinguishable from no query at all — and finite, so a focused file with
# nothing pointing at it still loses to the hub everything calls.
my constant QUERY-BOOST = 10;
my constant FOCUS-BOOST = 50;

#| Split the C<query> parameter into words.  Commas or spaces, either way; a
#| model that writes C<"parser, tokenizer"> means two words.
sub query-words(Str:D $query --> List) is export {
	$query.split(/<[\s,]>+/).grep(*.chars).map(*.lc).unique.List;
}

#| Split the C<focus> parameter into normalised relative paths.
sub focus-paths(Str:D $focus --> List) is export {
	$focus.split(/<[\s,]>+/).grep(*.chars).map({
		my Str $p = $_.subst('\\', '/', :g);
		$p .= substr(2) while $p.starts-with('./');
		$p .= chop while $p.ends-with('/');
		$p;
	}).grep(*.chars).unique.List;
}

#| Rank the mapped files against each other.
#|
#| C<%tags> is rel-path => the Hash C<extract-tags> returned.  The result is
#|
#|     %( ranks      => %( 'hub.py' => 0.41, … ),
#|        references => %( 'frobnicate' => 3, … ),
#|        weights    => %( 'frobnicate' => 3e0, 'new' => 1e0, … ) )
#|
#| where C<ranks> is a personalized PageRank over the graph "file A refers to
#| an identifier file B defines", C<references> counts how often each defined
#| identifier is referred to anywhere in the map, and C<weights> is that count
#| shared out among the files that define the name — which is what decides
#| WHICH definitions of a file are worth printing once the budget bites.
#|
#| The ranking is deliberately global rather than local: a file is important
#| because the rest of the tree leans on it, not because it is big or because
#| it sorts early.  A tree with no edges at all — one file, or ten unrelated
#| scripts — degenerates to the personalization vector, which is uniform
#| unless a query or focus said otherwise, and the same code path produces it.
sub rank-files(%tags, Str:D $query, @focus --> Hash:D) is export {
	my @paths = %tags.keys.sort;
	return %( ranks => %(), references => %(), weights => %() ) unless @paths;

	# Which files define each identifier.  A Raku module also "defines" its
	# own module name, so `use Foo::Bar` in one file is an edge to the file
	# that is Foo::Bar without either file having to say so.
	my %definers;
	for @paths -> $path {
		%definers{.<name>}.push($path) for %tags{$path}<defs>.list;
		with module-name-for($path) -> $module {
			%definers{$module}.push($path);
		}
	}
	my @names = %definers.keys.sort;
	%definers{$_} = %definers{$_}.unique.sort.List for @names;

	my %references;
	my %referrers;
	my %edges;
	for @paths -> $from {
		my $refs = %tags{$from}<refs>;
		next without $refs;
		# Sorted rather than in Bag order: these are floating-point sums,
		# and a sum whose order changes between runs can flip a tie.
		for $refs.keys.sort -> $name {
			my @definers = (%definers{$name} // ()).list;
			next unless @definers;
			my Int:D $count = $refs{$name};
			%references{$name} += $count;
			%referrers{$name}++;
			my Num:D $weight = common-discount(@definers.elems);
			for @definers -> $to {
				next if $to eq $from;
				%edges{$from}{$to} += $count * $weight / @definers.elems;
			}
		}
	}

	# The same normalisation the edges get, applied to the definitions
	# themselves.  Without it, `new` is the single most-referenced name in
	# most codebases and therefore the one definition every file gets to
	# show — every file that happens to define one, which is most of them.
	# Sharing a name's references among its definers says what is actually
	# meant: forty files defining `new` each own a fortieth of the interest
	# in it, while the one file defining the symbol everything imports owns
	# all of that.  The floor keeps a referenced definition from sinking
	# below an unreferenced one.
	#
	# Sharing is not enough on its own.  A name that most of the map REFERS
	# to identifies no part of it however few files declare one: `new` in a
	# Raku tree is one declaration and twelve hundred `.new` calls, almost
	# none of which mean that declaration, because an unqualified reference
	# scan cannot tell whose `new` it is looking at.  Such a name is floored
	# rather than discounted — a discount large enough to matter against a
	# thousand references is a floor with extra arithmetic — and only where
	# breadth means anything, which it does not in a map of three files.
	my Bool:D $breadth-is-meaningful = @paths.elems >= BREADTH-SAMPLE-FLOOR;
	my Real:D $ubiquitous = @paths.elems * COMMON-REFERRER-SHARE;
	my %weights;
	for %references.keys.sort -> $name {
		if $breadth-is-meaningful && %referrers{$name} > $ubiquitous {
			%weights{$name} = 1e0;
			next;
		}
		my Int:D $definers = max(1, (%definers{$name} // ()).elems);
		%weights{$name} = max(1e0,
			%references{$name} * common-discount($definers) / $definers);
	}

	my %personal = personalization(%tags, @paths, $query, @focus);
	%(
		ranks      => page-rank(@paths, %edges, %personal),
		references => %references,
		weights    => %weights,
	);
}

# An identifier defined in more than a handful of files is a `main`, an
# `init` or a `new`: technically a definition everywhere, informative nowhere.
my sub common-discount(Int:D $definers --> Num:D) {
	$definers > COMMON-DEFINER-LIMIT ?? 0.1e0 !! 1e0;
}

# The module a Raku file would be `use`d as, or an undefined Str.  Everything
# up to and including the last 'lib' directory is dropped, so both
# 'lib/Foo/Bar.rakumod' and 'sub/dist/lib/Foo/Bar.rakumod' are Foo::Bar, and a
# tree mapped from inside its own lib/ still works.
my sub module-name-for(Str:D $path --> Str) {
	my Int:D $dot = $path.rindex('.') // -1;
	return Str if $dot < 1;
	my Str:D $ext = $path.substr($dot + 1).lc;
	return Str unless $ext eq 'rakumod' || $ext eq 'pm6';
	my @parts = $path.substr(0, $dot).split('/').grep(*.chars);
	my Int $lib = -1;
	for ^@parts.elems -> $i {
		$lib = $i if @parts[$i] eq 'lib';
	}
	@parts = @parts[$lib + 1 .. *];
	return Str unless @parts;
	@parts.join('::');
}

# The seed vector: where a random walk restarts.  Uniform by default, so a
# plain map is "what does this tree lean on"; weighted by query and focus when
# the caller had something specific in mind, so the same machinery answers
# "what does this tree lean on, near THIS" without a second algorithm.
my sub personalization(%tags, @paths, Str:D $query, @focus --> Hash:D) {
	my @words = query-words($query);
	my %personal;
	for @paths -> $path {
		my Num:D $seed = 1e0;
		$seed *= QUERY-BOOST if @words && matches-query($path, %tags{$path}, @words);
		$seed *= FOCUS-BOOST if @focus && matches-focus($path, @focus);
		%personal{$path} = $seed;
	}
	my Num:D $total = [+] @paths.map({ %personal{$_} });
	return %personal unless $total > 0;
	%personal{$_} /= $total for @paths;
	%personal;
}

my sub matches-query(Str:D $path, %file, @words --> Bool:D) {
	my Str:D $lower = $path.lc;
	return True if @words.first({ $lower.contains($_) }).defined;
	for %file<defs>.list -> %def {
		my Str:D $name = %def<name>.lc;
		return True if @words.first({ $name.contains($_) }).defined;
	}
	False;
}

# A focus entry names a file — 'src/hub.py', or just 'hub.py' when the caller
# could not be bothered with the directory — or a directory, in which case
# everything below it is focused.
my sub matches-focus(Str:D $path, @focus --> Bool:D) {
	so @focus.first({
		$path eq $_ || $path.ends-with('/' ~ $_) || $path.starts-with($_ ~ '/')
	}).defined;
}

# Personalized PageRank, hand-rolled over plain hashes.  Small enough to read
# in one sitting, which matters more here than the last decimal place: at the
# 5000-file valve this converges in well under the iteration cap, and the only
# thing anyone consumes is the ORDER it produces.
my sub page-rank(@paths, %edges, %personal --> Hash:D) {
	# Each file's out-edges, in a fixed order, with their total.  Both are
	# constant for the whole run: computing them inside the iteration would
	# sort and sum the same numbers thirty times over, and the sorted order
	# is what keeps the floating-point sums identical between runs.
	my %targets;
	my %out-total;
	for @paths -> $from {
		my $out = %edges{$from};
		next without $out;
		%targets{$from} = $out.keys.sort.List;
		%out-total{$from} = [+] %targets{$from}.map({ $out{$_} });
	}

	my %rank = %personal;
	for ^MAX-ITERATIONS {
		my %next;
		%next{$_} = 0e0 for @paths;

		# Rank that has nowhere to flow — a file referring to nothing that
		# is defined in the map — is not thrown away, or the totals would
		# shrink every iteration.  It goes back into the seed vector, which
		# is what makes a query keep its grip on a sparse graph.
		my Num:D $dangling = 0e0;
		for @paths -> $from {
			my $out = %edges{$from};
			unless $out {
				$dangling += %rank{$from};
				next;
			}
			my Num:D $total = %out-total{$from};
			for %targets{$from}.list -> $to {
				%next{$to} += DAMPING * %rank{$from} * $out{$to} / $total;
			}
		}

		my Num:D $restart = (1 - DAMPING) + DAMPING * $dangling;
		%next{$_} += $restart * %personal{$_} for @paths;

		my Num:D $delta = [+] @paths.map({ abs(%next{$_} - %rank{$_}) });
		%rank = %next;
		last if $delta < CONVERGENCE;
	}
	%rank;
}

#| The mapped files in the order they should be printed: most-referenced
#| first, and — when two files are tied, which happens the moment a tree has
#| no edges at all — by path, so the same tree always maps the same way.
sub order-files(%tags, %ranks --> List) is export {
	%tags.keys.sort({ (%ranks{$^b} // 0) <=> (%ranks{$^a} // 0) || $^a leg $^b }).List;
}

#| The definitions of one file, best first: the ones the rest of the tree
#| refers to and few other files also define, then the ones that appear
#| earliest.  C<%weights> is C<rank-files>' C<weights> entry.  This is the
#| order the budget eats from the bottom of.
sub order-defs(%file, %weights --> List) is export {
	%file<defs>.list.sort({
		def-weight($^b, %weights) <=> def-weight($^a, %weights)
		|| $^a<line> <=> $^b<line>
		|| $^a<name> leg $^b<name>
	}).List;
}

my sub def-weight(%def, %weights --> Num:D) {
	%weights{%def<name>} // 1e0;
}

# === Rendering ===

#| Render the ranked map, fitting it inside C<$max-chars>.
#|
#| C<@files> is a list of C<%( path => Str, defs => [ %( line, text ), … ] )>
#| in rank order, each file's definitions in best-first order.  C<%counts>
#| carries what the summary line has to say: C<mapped>, C<skipped>,
#| C<definitions>, C<seeds> (a list of 'query' and/or 'focus') and C<stopped>.
#|
#| The budget is spent whole blocks at a time.  A half-printed file would
#| invite exactly the mistake the tool exists to prevent — reading a signature
#| that is not really there — so the map would rather show four files
#| completely than six of them in pieces.
sub render-map(@files, Int:D $max-chars, %counts --> Str:D) is export {
	my @printable = @files.grep({ .<defs>.elems });
	my Int:D $total = @printable.elems;
	return summary-line(%counts, 0, 0) unless $total;

	# The summary is not optional and goes last, so its length comes off the
	# top rather than being discovered at the end.
	my Str:D $whole = summary-line(%counts, $total, $total);
	my @blocks = @printable.map({ render-block($_, DEFS-PER-FILE) });
	my Int:D $needed = block-length(@blocks);

	return (|@blocks, $whole).join("\n\n")
		if $needed <= $max-chars - $whole.chars - 2;

	# Past this point the map is definitely being cut, which makes the
	# summary longer than the one measured above — it gains the clause that
	# says so.  Budgeting against the short one would produce an answer that
	# overran the limit by exactly the length of its own apology.
	my Int:D $budget = max(0, $max-chars
		- summary-line(%counts, $total - 1, $total).chars - 2);

	# Everything shrinks by the same factor first, so a map that is twice too
	# big loses the tail of every file rather than half its files.  Whatever
	# still does not fit is then dropped whole.
	my Int:D $cap = max(1, ($budget / $needed * DEFS-PER-FILE).floor);
	@blocks = @printable.map({ render-block($_, $cap) });

	my @kept;
	for @blocks -> $block {
		last if @kept && block-length((|@kept, $block)) > $budget;
		@kept.push: $block;
	}
	# The top file always survives, even when it alone is over budget: a map
	# that answered "nothing fits" would be worse than useless.  It is
	# trimmed to its single best definition first.
	if @kept.elems == 1 && @kept[0].chars > $budget {
		@kept[0] = render-block(@printable[0], 1);
	}

	(|@kept, summary-line(%counts, @kept.elems, $total)).join("\n\n");
}

# What a run of blocks costs once joined by their blank line.
my sub block-length(@blocks --> Int:D) {
	return 0 unless @blocks;
	([+] @blocks.map(*.chars)) + 2 * (@blocks.elems - 1);
}

# One file's block: its path, then its definition lines in FILE order — the
# selection is by rank, the printing is by line, because a skeleton read out
# of order is not a skeleton.  A gap between printed lines is marked, so the
# reader knows something was left out rather than assuming two definitions
# are adjacent.
my sub render-block(%file, Int:D $cap --> Str:D) {
	my @chosen = %file<defs>.head($cap).sort({
		$^a<line> <=> $^b<line> || $^a<name> leg $^b<name>
	});
	my @lines = %file<path> ~ ':';
	my Int $previous;
	for @chosen -> %def {
		@lines.push: '⋮' if $previous.defined && %def<line> > $previous + 1;
		@lines.push: '  ' ~ %def<line> ~ ': ' ~ %def<text>;
		$previous = %def<line>;
	}
	@lines.join("\n");
}

# The last line of every map, present even when nothing else is.  It is the
# only place the model learns what it is NOT looking at: how much was skipped,
# whether the walk gave up, whether the budget cut the tail off.
my sub summary-line(%counts, Int:D $shown, Int:D $printable --> Str:D) {
	my Int:D $mapped = %counts<mapped> // 0;
	my Int:D $skipped = %counts<skipped> // 0;
	my Int:D $defs = %counts<definitions> // 0;
	my @seeds = (%counts<seeds> // ()).list;

	my Str:D $text = '[mapped ' ~ $mapped ~ ($mapped == 1 ?? ' file' !! ' files');
	$text ~= " ($skipped skipped: unsupported/binary/too-large)" if $skipped;
	$text ~= ', ' ~ $defs ~ ($defs == 1 ?? ' definition' !! ' definitions');
	$text ~= '; ranked by references';
	$text ~= ', seeded by ' ~ @seeds.join(' and ') if @seeds;
	$text ~= '; stopped at ' ~ MAP-FILE-LIMIT ~ ' files' if %counts<stopped>;
	$text ~= "; showing $shown of $printable files, raise max-chars for the rest"
		if $shown < $printable;
	$text ~ ']';
}
