BEGIN { $| = 1; print "1..7\n"; }

# The trailing option hash, and the one option there is: inherit.
#
# Inheriting everything is what these functions have always done and stays the
# default; { inherit => 0 } holds the child to 0/1/2. On Windows that means
# leaving the rest out of the descriptor block (and out of the handle list,
# where the attribute list is available); on POSIX it means marking them
# close-on-exec for the duration of the spawn, dup2 onto 0/1/2 clearing that
# again for the three that are redirected.
#
# The option hash may take the place of envp, since an option hash and an
# environment list cannot be mistaken for one another.
#
# As in 05_fdtable.t the two pipes are kept one-way: a parent blocking on the
# same pipe end a child is opening would deadlock it on Windows.

use Proc::FastSpawn;
use Config;

print "ok 1\n";

my $perl = $Config{perlpath}; # $^X may be corrupted when linked against -lpthread

# says "yes" or "no" on its stdout, according to whether it can reach the
# descriptor it was told about by number
my $code = '
   my ($fd) = @ARGV;
   my $ok = (open my $h, "<&" . $fd) ? 1 : 0;
   binmode STDOUT;
   print STDOUT $ok ? "yes" : "no";
   exit 0;
';

sub reaches {
   my (@opts) = @_;

   pipe my $dnr, my $dnw or die "pipe: $!";  # the descriptor under test
   pipe my $upr, my $upw or die "pipe: $!";  # the child's stdout
   binmode $_ for $dnr, $dnw, $upr, $upw;

   fd_inherit fileno $_, 1 for $dnr, $dnw, $upw;

   my $pid = &spawn3 (0, fileno $upw, 2, $perl,
                      [qw(perl -e), $code, fileno $dnr], @opts);

   close $dnw;
   close $upw;

   my $out = do { local $/; <$upr> };
   waitpid $pid, 0;

   defined $out ? $out : "";
}

print +(reaches ()                     eq "yes") ? "" : "not ", "ok 2 # default\n";
print +(reaches ({ inherit => 1 })     eq "yes") ? "" : "not ", "ok 3 # inherit => 1\n";
print +(reaches ({ inherit => 0 })     eq "no")  ? "" : "not ", "ok 4 # inherit => 0\n";

# the answer came back over the child's stdout, so 0/1/2 kept working while the
# rest was held back - and spawn took the hash with no envp in front of it
my $pid = spawn $perl, [qw(perl -e), "exit 7"], { inherit => 0 };
waitpid $pid, 0;
print +($? >> 8 == 7) ? "" : "not ", "ok 5 # spawn with options and no envp\n";

my $err = do { eval { spawn $perl, [qw(perl -e), "exit 0"], { bogus => 1 } }; $@ };
$err =~ s/\n.*//s;
print $err =~ /unknown option/ ? "" : "not ", "ok 6 # $err\n";

# in the option slot proper, where it cannot be mistaken for envp
$err = do { eval { spawn $perl, [qw(perl -e), "exit 0"], undef, \"scalar" }; $@ };
$err =~ s/\n.*//s;
print $err =~ /hash reference/ ? "" : "not ", "ok 7 # $err\n";
