use Test;

#|( Shared fixtures for the FileSystem toolkit tests: a throwaway sandbox on
    disk, plus the handle-request idiom every tool call is driven through.
    Deliberately does not `use MCP::Server::Tool::FileSystem` — t/04 needs
    to load the pack dynamically and must not have it pulled in behind its
    back.

    This is test support, not library surface -- it ships inside the dist's
    own namespace (rather than under C<t/lib>) deliberately, so that
    C<zef install>'s test phase precompiles it as part of C<lib/> staging
    before any test file runs. A C<t/lib> CompUnit repo starts cold on a
    fresh C<zef install> and races when parallel test files each pull in
    the fixture's dependency chain, which can fail the install outright;
    moving test support into C<lib/> under a C<::Test> namespace is the
    fleet-wide fix for that failure class. )
unit module MCP::Server::Tool::FileSystem::Test::Kit;

use NativeCall;

# For open-handle-count on Windows, which publishes no listing of a process's
# handles: kernel32 counts them itself.
my sub win-current-process(--> Pointer)
	is native('kernel32') is symbol('GetCurrentProcess') { * }
my sub win-process-handle-count(Pointer, uint32 is rw --> int32)
	is native('kernel32') is symbol('GetProcessHandleCount') { * }

#| How many files, pipes, sockets and other OS handles this process holds open,
#| for the tests that assert a tool call gives back everything it takes.  Read
#| from the kernel's own list where it publishes one — C</proc/self/fd> on
#| Linux, C</dev/fd> on macOS and the BSDs — and from GetProcessHandleCount on
#| Windows, which counts thread and event handles too.  So only the difference
#| between two readings means anything, never one reading on its own.  The
#| listing's own directory handle is in every reading, so it cancels out of a
#| difference.  It is read to its end (C<.elems>) because a listing left
#| unfinished keeps its handle open after the reading is taken.
sub open-handle-count(--> Int:D) is export {
	if $*DISTRO.is-win {
		my uint32 $count = 0;
		die 'open-handle-count: GetProcessHandleCount failed'
			unless win-process-handle-count(win-current-process(), $count);
		return $count;
	}
	for '/proc/self/fd', '/dev/fd' -> $listing {
		my $count = try $listing.IO.dir.elems;
		return $count if $count.defined;
	}
	die 'open-handle-count: this host publishes no list of the descriptors a process holds';
}

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

#| The advertised schema of one tool, for the tests that pin a tool's
#| parameter set.
sub tool-schema($server, Str:D $name --> Hash) is export {
	my %response = $server.handle-request({
		jsonrpc => '2.0', id => 98, method => 'tools/list',
	});
	my $tool = %response<result><tools>.first({ .<name> eq $name });
	($tool // {}).Hash;
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
