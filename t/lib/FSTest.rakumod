use Test;

# Shared fixtures for the FileSystem toolkit tests: a throwaway sandbox on
# disk, plus the handle-request idiom every tool call is driven through.
# Deliberately does not `use MCP::Server::Tool::FileSystem` — t/04 needs to load
# the pack dynamically and must not have it pulled in behind its back.
unit module FSTest;

#| A fresh, empty directory unique to this process and tag.  Returned resolved,
#| because the toolkit resolves its root and paths must be comparable (on macOS
#| $*TMPDIR lives under a symlinked /var).
sub make-sandbox(Str:D $tag --> IO::Path:D) is export {
	my $dir = $*TMPDIR.add("mcp-fs-{$tag}-{$*PID}");
	nuke($dir);
	$dir.mkdir;
	$dir.resolve;
}

#| Recursive delete that unlinks symlinks instead of descending into them — the
#| containment tests plant links pointing outside the sandbox.
sub nuke(IO::Path:D $path) is export {
	if $path.l {
		$path.unlink;
	} elsif $path.d {
		my @children = $path.dir.List;
		nuke($_) for @children;
		$path.rmdir;
	} elsif $path.e {
		$path.unlink;
	}
}

sub call-tool($server, Str:D $name, %arguments --> Hash) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 1, method => 'tools/call',
		params => { name => $name, arguments => %arguments },
	});
}

sub result-text(%response --> Str) is export {
	%response<result><content>[0]<text> // '';
}

sub result-errored(%response --> Bool:D) is export {
	so %response<result><isError>;
}

sub tool-names($server --> List) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 99, method => 'tools/list',
	})<result><tools>.map(*<name>).sort.list;
}

#| Assert that a tool call came back as an error result carrying $needle.
sub errors-with($server, Str:D $name, %arguments, Str:D $needle, Str:D $desc) is export {
	my %response = call-tool($server, $name, %arguments);
	my $text     = result-text(%response);
	my $matched  = result-errored(%response) && $text.contains($needle);
	ok $matched, $desc;
	diag "result was: {%response<result>.raku}" unless $matched;
}

#| Assert that &code throws something whose message contains $needle.
sub dies-with(&code, Str:D $needle, Str:D $desc) is export {
	my Str $message;
	{
		code();
		CATCH { default { $message = .message } }
	}
	my $matched = $message.defined && $message.contains($needle);
	ok $matched, $desc;
	diag "message was: {$message // '(nothing thrown)'}" unless $matched;
}
