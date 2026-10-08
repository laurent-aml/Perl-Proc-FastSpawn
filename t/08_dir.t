BEGIN { $| = 1; print "1..11\n"; }

use Proc::FastSpawn;
use File::Temp ();
use File::Spec;
use Cwd ();

# Where we started. The child changes directory on most platforms, and on the
# vfork path it does so while still sharing the parent's address space - so if
# a system's vfork shared its filesystem state as well, the chdir would move
# *us*. Linux cannot (vfork is clone without CLONE_FS, so the cwd is copied),
# but that is a per-platform property, and this is where it would show.
my $cwd0 = Cwd::getcwd;

print "ok 1\n";

my $tmp  = File::Temp->newdir;
my $dir  = "$tmp";
my $deep = File::Spec->catdir ($dir, "sub");
mkdir $deep or die;

# a script that prints its working directory, so the child can report back
sub helper {
  my ($path) = @_;
  open my $fh, ">", $path or die;
  print $fh "#!/bin/sh\npwd\n";
  close $fh;
  chmod 0755, $path;
}
helper (File::Spec->catfile ($deep, "where.sh"));

sub run {
  # spawn3 is prototyped, so the arguments cannot be passed through an array:
  # each $ slot imposes scalar context and @args would collapse to its count.
  my ($opts, $path, $argv) = @_;
  pipe my $r, my $w or die;
  my $c = spawn3 0, fileno $w, 2, $path, $argv, $opts;
  close $w;
  my $out = do { local $/; <$r> };
  waitpid $c, 0;
  $out =~ s/\n\z// if defined $out;
  ($out, $? >> 8)
}

# the child runs in dir
{
  my ($out) = run ({ dir => $deep }, "/bin/pwd", ["pwd"]);
  print +($out && -s File::Spec->catfile ($out, "where.sh") ? "" : "not "), "ok 2 # $out\n";
}

# without dir it runs where we are
{
  my ($out) = run ({}, "/bin/pwd", ["pwd"]);
  print +(defined $out && length $out ? "" : "not "), "ok 3\n";
}

# a relative program is resolved against dir, not against our cwd
{
  my ($out, $st) = run ({ dir => $deep }, "./where.sh", ["where.sh"]);
  print +($st == 0            ? "" : "not "), "ok 4 # exit $st\n";
  print +($out && -s File::Spec->catfile ($out, "where.sh") ? "" : "not "), "ok 5\n";
}

# spawn3p: a bare name stays a PATH lookup even with dir set
{
  pipe my $r, my $w or die;
  my $c = spawn3p 0, fileno $w, 2, "pwd", ["pwd"], { dir => $deep };
  close $w;
  my $out = do { local $/; <$r> }; waitpid $c, 0; $out =~ s/\n\z//;
  print +($? == 0 ? "" : "not "), "ok 6 # exit ", $? >> 8, "\n";
  print +($out && -s File::Spec->catfile ($out, "where.sh") ? "" : "not "), "ok 7\n";
}

# spawn/spawnp take it too
{
  pipe my $r, my $w or die;
  fd_inherit fileno $w;
  my $pid = spawnp "sh", ["sh", "-c", "pwd >&" . fileno $w], { dir => $deep };
  close $w;
  my $out = do { local $/; <$r> }; waitpid $pid, 0; $out =~ s/\n\z//;
  print +($out && -s File::Spec->catfile ($out, "where.sh") ? "" : "not "), "ok 8 # $out\n";
}

# a directory that is not there cannot be reported to us: it is exit 126,
# which is what tells it from a failed exec (127)
{
  my (undef, $st) = run ({ dir => File::Spec->catdir ($dir, "nope") }, "/bin/pwd", ["pwd"]);
  print +($st == 126 ? "" : "not "), "ok 9 # exit $st\n";
}
{
  my (undef, $st) = run ({ dir => $deep }, File::Spec->catfile ($deep, "nope"), ["nope"]);
  print +($st == 127 ? "" : "not "), "ok 10 # exit $st\n";
}

# after all of that, we are still where we started
{
  my $now = Cwd::getcwd;
  print +($now eq $cwd0 ? "" : "not "), "ok 11 # $now\n";

}
