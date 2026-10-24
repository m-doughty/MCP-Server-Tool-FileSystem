unit module MCP::Server::Tool::FileSystem::Test::FileTimeFixture;

# Test support: set a file's modification time to an exact instant, so a
# test can order files by time without sleeping and without depending on
# how fine the filesystem's timestamps are. Raku has no utime, so this is
# the C runtime's: _wutime64 on Windows (UTF-16 path), utime elsewhere.

use NativeCall;

# struct utimbuf / struct __utimbuf64: access time, then modification
# time, whole seconds since the epoch. time_t is C long on LP64 POSIX;
# Windows names the 64-bit variant explicitly.
my class UtimbufPosix is repr('CStruct') { has long  $.actime; has long  $.modtime; }
my class Utimbuf64    is repr('CStruct') { has int64 $.actime; has int64 $.modtime; }

my sub posix-utime(Str is encoded('utf8'), UtimbufPosix --> int32)
	is native is symbol('utime') { * }
my sub win-wutime64(CArray[uint16], Utimbuf64 --> int32)
	is native('ucrtbase') is symbol('_wutime64') { * }

#| Set both the access and the modification time of $path to $when,
#| truncated to the whole second. Dies when the C runtime refuses.
sub set-file-mtime(IO::Path:D $path, Instant:D $when --> Nil) is export {
	my Int $secs = $when.to-posix.head.floor;
	my int32 $rc = $*DISTRO.is-win
		?? win-wutime64(
			CArray[uint16].new(|$path.absolute.encode('utf16').list, 0),
			Utimbuf64.new(:actime($secs), :modtime($secs)))
		!! posix-utime($path.absolute,
			UtimbufPosix.new(:actime($secs), :modtime($secs)));
	die "set-file-mtime: could not set the time of $path" if $rc != 0;
}
