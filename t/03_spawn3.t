BEGIN { $| = 1; print "1..15\n"; }

use Proc::FastSpawn;
use Config;

my $perl = $Config{perlpath}; # $^X may be corrupted when linked against -lpthread

print "ok 1\n";

# Slurp a filehandle to EOF.
sub slurp { my $fh = shift; local $/; my $s = <$fh>; defined $s ? $s : "" }

# --- spawn3: redirect the child's STDOUT onto a pipe (fd_in/fd_err inherited) ---
{
  pipe my $r, my $w or die;
  binmode $r; binmode $w;
  my $pid = spawn3 0, fileno $w, 2, $perl, [qw(perl -e), 'binmode STDOUT; print "hello3"'];
  close $w;
  print $pid ? "" : "not ", "ok 2\n";
  my $out = slurp $r;
  print +($pid == waitpid $pid, 0) ? "" : "not ", "ok 3\n";
  print $out eq "hello3" ? "" : "not ", "ok 4 # $out\n";
}

# --- spawn3: redirect STDIN (from a pipe) and STDOUT (to a pipe) ---
{
  pipe my $cr, my $cw or die; # child reads $cr; parent writes $cw
  binmode $cr; binmode $cw;
  pipe my $or, my $ow or die; # child writes $ow; parent reads $or
  binmode $or; binmode $ow;
  my $pid = spawn3 fileno $cr, fileno $ow, 2, $perl,
    [qw(perl -e), 'binmode STDIN; binmode STDOUT; my $x = <STDIN>; print "got:$x"'];
  close $cr; close $ow;
  print $pid ? "" : "not ", "ok 5\n";
  syswrite $cw, "ping\n"; close $cw;
  my $out = slurp $or;
  print +($pid == waitpid $pid, 0) ? "" : "not ", "ok 6\n";
  print $out eq "got:ping\n" ? "" : "not ", "ok 7 # $out\n";
}

# --- spawn3: redirect STDERR onto a pipe (STDOUT left inherited) ---
{
  pipe my $r, my $w or die;
  binmode $r; binmode $w;
  my $pid = spawn3 0, 1, fileno $w, $perl, [qw(perl -e), 'binmode STDERR; print STDERR "onerr"'];
  close $w;
  print $pid ? "" : "not ", "ok 8\n";
  my $out = slurp $r;
  waitpid $pid, 0;
  print $out eq "onerr" ? "" : "not ", "ok 9 # $out\n";
}

# --- spawn3p: like spawn3 but searches PATH for the program ---
{
  pipe my $r, my $w or die;
  binmode $r; binmode $w;
  my $pid = spawn3p 0, fileno $w, 2, "echo", [qw(echo viapath)];
  close $w;
  print $pid ? "" : "not ", "ok 10\n";
  my $out = slurp $r;
  waitpid $pid, 0;
  print $out eq "viapath\n" ? "" : "not ", "ok 11 # $out\n";
}

# --- spawn3: an explicit envp is passed to the child ---
{
  pipe my $r, my $w or die;
  binmode $r; binmode $w;
  my $pid = spawn3 0, fileno $w, 2, $perl,
    [qw(perl -e), 'binmode STDOUT; print $ENV{FOO}'], ["FOO=barbar"];
  close $w;
  print $pid ? "" : "not ", "ok 12\n";
  my $out = slurp $r;
  waitpid $pid, 0;
  print $out eq "barbar" ? "" : "not ", "ok 13 # $out\n";
}

# --- spawn3: the (redirected) source fd is closed in the child, not leaked ---
{
  pipe my $r, my $w or die;
  binmode $r; binmode $w;
  my $src = fileno $w;
  # After dup2($src -> 1) the child's STDOUT is the pipe; the source $src (>2)
  # must have been closed, so re-opening it should fail.
  my $pid = spawn3 0, $src, 2, $perl,
    [qw(perl -e), 'binmode STDOUT; print open(my $x, ">&=" . $ARGV[0]) ? "leak" : "closed"', $src];
  close $w;
  print $pid ? "" : "not ", "ok 14\n";
  my $out = slurp $r;
  waitpid $pid, 0;
  print $out eq "closed" ? "" : "not ", "ok 15 # $out\n";
}
