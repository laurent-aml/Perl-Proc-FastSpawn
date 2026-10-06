BEGIN { $| = 1; print "1..11\n"; }

# Proc::FastSpawn::setOptions - the process-wide CreateProcess defaults.
#
# create_new_console is deliberately not exercised: it does what it says and
# puts a console window on the screen, which a test run should not do. The
# flags are shown to reach CreateProcess through detached_process instead,
# whose effect is just as visible from the child and costs no UI.

use Proc::FastSpawn;
use Config;

my $perl = $Config{perlpath}; # $^X may be corrupted when linked against -lpthread

my %now = Proc::FastSpawn::setOptions ();
print +(keys %now == 4 && !grep $_, values %now) ? "" : "not ",
      "ok 1 # everything off to begin with\n";

my %old = Proc::FastSpawn::setOptions (create_no_window => 1);
%now = Proc::FastSpawn::setOptions ();
print +(!$old {create_no_window} && $now {create_no_window}) ? "" : "not ",
      "ok 2 # set, and the old setting came back\n";

Proc::FastSpawn::setOptions (%old);
%now = Proc::FastSpawn::setOptions ();
print +(!$now {create_no_window}) ? "" : "not ", "ok 3 # restored from what was returned\n";

eval { Proc::FastSpawn::setOptions (create_no_windo => 1) };
print $@ =~ /unknown option/ ? "" : "not ", "ok 4 # a misspelling is fatal\n";

eval { Proc::FastSpawn::setOptions ("lonely") };
print $@ =~ /key => value/ ? "" : "not ", "ok 5 # an odd list is fatal\n";

eval { Proc::FastSpawn::setOptions (create_new_console => 1, detached_process => 1) };
%now = Proc::FastSpawn::setOptions ();
print +($@ =~ /mutually exclusive/
        && !$now {create_new_console} && !$now {detached_process}) ? "" : "not ",
      "ok 6 # a rejected call changes nothing\n";

# What the child can see of a console says which flags CreateProcess got.
sub child_console {
   my (%opts) = @_;
   my %save = Proc::FastSpawn::setOptions (%opts);

   pipe my $r, my $w or die "pipe: $!";
   binmode $r; binmode $w;
   fd_inherit fileno $w, 1;

   my $pid = spawn3 0, fileno $w, 2, $perl,
                    [qw(perl -e), 'binmode STDOUT;
                                   print STDOUT open (my $c, ">", q(CONOUT$)) ? "console" : "none"'];
   close $w;
   my $out = do { local $/; <$r> };
   waitpid $pid, 0;

   Proc::FastSpawn::setOptions (%save);
   defined $out ? $out : "";
}

# Only meaningful where there is a console to share in the first place, and
# where CONOUT$ is a console rather than a file waiting to be created.
my $console = $^O eq "MSWin32" && open my $c, ">", "CONOUT\$";
close $c if $console;

if (!$console) {
   print "ok $_ # skip no console to inherit\n" for 7 .. 9;
} else {
   print +(child_console ()                      eq "console") ? "" : "not ",
         "ok 7 # by default the child shares our console\n";

   print +(child_console (detached_process => 1) eq "none")    ? "" : "not ",
         "ok 8 # detached_process reaches CreateProcess\n";

   # still a console, just one with no window on it - and the child ran and
   # its redirected stdout worked, which is the part that would break if the
   # flag were interfering with the handles
   print +(child_console (create_no_window => 1) eq "console") ? "" : "not ",
         "ok 9 # create_no_window leaves the child working\n";
}

# The two sets of options are deliberately disjoint. Per-call options are for
# things that mean something on every platform; anything that only makes sense
# on one lives here, so portable code never has to guard a spawn call. Neither
# side should quietly start accepting the other's names.
my $leaked = 0;

for my $flag (qw(create_no_window detached_process create_new_console
                 create_new_process_group)) {
   eval { spawn $perl, [qw(perl -e), "exit 0"], { $flag => 1 } };
   $leaked = 1 unless $@ =~ /unknown option/;
}

print $leaked ? "not " : "", "ok 10 # creation flags are not per-call options\n";

eval { Proc::FastSpawn::setOptions (inherit => 1) };
print $@ =~ /unknown option/ ? "" : "not ", "ok 11 # inherit is not a global setting\n";
