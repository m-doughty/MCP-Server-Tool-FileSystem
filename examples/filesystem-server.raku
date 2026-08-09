#!/usr/bin/env raku

# A two-root MCP server: a writable scratch workspace and a read-only view of
# this checkout. Run it over stdio with:
#
#   raku -I lib -I ../MCP-Server/lib examples/filesystem-server.raku
#
# ...or, once both distributions are installed, just `raku examples/filesystem-server.raku`.
# Then drive it by hand — one JSON-RPC message per line on stdin:
#
#   {"jsonrpc":"2.0","id":1,"method":"tools/list"}
#   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"docs_glob","arguments":{"pattern":"*.rakudoc"}}}
#   {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"work_write","arguments":{"path":"hello.txt","content":"hi there"}}}
#   {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"docs_grep","arguments":{"pattern":"symlink","context":1}}}
#   {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"work_edit","arguments":{"path":"hello.txt","old-string":"hi","new-string":"hello"}}}
#
# docs_* is read-only, so docs_edit and docs_delete are not registered at all —
# tools/list on that prefix shows only read, list, glob, grep and stat.

use MCP::Server;

my $workspace = $*TMPDIR.add('mcp-filesystem-example');
$workspace.mkdir;

# The toolkit is named, not imported: MCP::Server loads it at runtime, exactly
# as it would from a --config file.
my $server = MCP::Server.new(
	:name<filesystem-example>,
	:version<1.0>,
	:instructions(
		"Two sandboxes: work_* is a writable scratch directory at {$workspace}, "
		~ 'docs_* is a read-only view of the distribution docs. '
		~ 'All paths are relative to the sandbox root.'
	),
	:tools[
		'FileSystem' => { root => $workspace.Str, prefix => 'work' },
		'FileSystem' => { root => $*CWD.add('docs').Str, prefix => 'docs', 'read-only' => True },
	],
);

$server.run;
