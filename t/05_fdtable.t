BEGIN { $| = 1; print "1..7\n"; }

# A child must be able to reach an inherited descriptor by number, not just as
# one of its three standard handles.  On POSIX that falls out of fork/exec; on
# Windows it only happens if the spawn hands over the C runtime's descriptor
# block, which CreateProcess does not do by itself - so this is really a
# Windows test, and it runs everywhere so the behaviour stays the same on both.
#
# Two pipes, each used in one direction only: "down" carries a token the parent
# wrote before the spawn, "up" carries the child's answer.  They have to stay
# separate.  On Windows a pipe end is a synchronous file object and every
# duplicate of it - the child's inherited copy included - shares that object's
# I/O lock, so if the parent sat in a blocking read on the same end the child
# were opening, the child's open would block in the kernel until the parent's
# read finished.  Nobody here touches an end the other side is reading.
#
# The child reports into a file as well as down the pipe, so "the child never
# ran" stays distinguishable from "the child ran but could not see the fd".

use Proc::FastSpawn;
use Config;
use File::Temp ();

print "ok 1\n";

my $perl = $Config{perlpath}; # $^X may be corrupted when linked against -lpthread

my (undef, $log) = File::Temp::tempfile (UNLINK => 0);

pipe my $dnr, my $dnw or die "pipe: $!"; # parent -> child
pipe my $upr, my $upw or die "pipe: $!"; # child  -> parent

binmode $_ for $dnr, $dnw, $upr, $upw;

fd_inherit fileno $_, 1 for $dnr, $dnw, $upr, $upw;

# written before the spawn so the child finds it waiting
syswrite $dnw, "ping";

my $code = '
   my ($logf, $dnfd, $upfd) = @ARGV;
   # Reach the descriptors BEFORE opening anything else: a file opened first
   # would take the lowest free number, which is exactly the number under test,
   # and the open would then succeed against the wrong thing.
   my $gr = (open my $cr, "<&" . $dnfd) ? 1 : 0;
   my $gw = (open my $cw, ">&" . $upfd) ? 1 : 0;
   my $got = "";
   if ($gr) { binmode $cr; sysread $cr, $got, 4 }
   if ($gw) { binmode $cw; syswrite $cw, "pong" }
   my $L;
   open $L, ">", $logf and do { print $L "ran\n$gr\n$gw\n$got\n"; close $L };
   exit 0;
';

my $pid = spawn $perl, [qw(perl -e), $code, $log, fileno $dnr, fileno $upw];
print $pid ? "" : "not ", "ok 2\n";

# drop the ends the child now owns: the write end so it sees EOF, and our copy
# of its write end so the read below ends when the child goes away
close $dnw;
close $upw;

my $out = do { local $/; <$upr> };
$out = "" unless defined $out;

print +($pid == waitpid $pid, 0) ? "" : "not ", "ok 3\n";
print $? == 0 ? "" : "not ", "ok 4 # status $?\n";

open my $L, "<", $log;
my @said = $L ? split /\n/, do { local $/; <$L> } : ();
close $L if $L;
unlink $log;

print +(@said && $said [0] eq "ran") ? "" : "not ", "ok 5 # child did not run\n";
print +(@said > 3 && $said [1] eq "1" && $said [3] eq "ping") ? "" : "not ",
      "ok 6 # read end not reachable by number\n";
print +(@said > 2 && $said [2] eq "1" && $out eq "pong") ? "" : "not ",
      "ok 7 # write end not reachable by number\n";
