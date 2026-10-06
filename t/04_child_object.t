BEGIN { $| = 1; print "1..12\n"; }

use Proc::FastSpawn;
use Config;

my $perl = $Config{perlpath};

print "ok 1\n";

# spawn3 returns a Proc::FastSpawn::Child, which stands in for the pid.
{
  my $c = spawn3 0, 1, 2, $perl, [qw(perl -e), 'exit 7'];

  print ref $c eq "Proc::FastSpawn::Child" ? "" : "not ", "ok 2 # ", ref $c, "\n";

  # behaves as the pid in every context the old plain pid was used in
  print $c > 0                 ? "" : "not ", "ok 3\n";   # numeric
  print "$c" eq $c->pid        ? "" : "not ", "ok 4\n";   # string
  print $c                     ? "" : "not ", "ok 5\n";   # boolean
  print $c + 0 == $c->pid      ? "" : "not ", "ok 6\n";   # arithmetic

  my %h = ($c => 1);                                      # hash key
  print +(keys %h)[0] eq $c->pid ? "" : "not ", "ok 7\n";

  # Win32::Process-compatible spellings
  print $c->GetProcessID == $c->pid ? "" : "not ", "ok 8\n";
  print !defined $c->GetProcessHandle || $c->GetProcessHandle == $c->handle
                                    ? "" : "not ", "ok 9\n";

  # handle() is defined only on Windows
  print +($^O eq "MSWin32" ? defined $c->handle : !defined $c->handle)
                                    ? "" : "not ", "ok 10\n";

  # and it still reaps as a pid
  my $r = waitpid $c, 0;
  print $r == $c                    ? "" : "not ", "ok 11\n";
  print +($? >> 8) == 7             ? "" : "not ", "ok 12 # ", $? >> 8, "\n";
}
