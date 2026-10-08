=head1 NAME

Proc::FastSpawn - fork+exec, or spawn, a subprocess as quickly as possible

=head1 SYNOPSIS

   use Proc::FastSpawn;

   # simple use
   my $pid = spawn "/bin/echo", ["echo", "hello, world"];
   ...
   waitpid $pid, 0;

   # with environment
   my $pid = spawn "/bin/echo", ["echo", "hello, world"], ["PATH=/bin", "HOME=/tmp"];

   # inheriting file descriptors
   pipe R, W or die;
   fd_inherit fileno W;
   my $pid = spawn "/bin/sh", ["sh", "-c", "echo a pipe >&" . fileno W];
   close W;
   print <R>;

   # redirecting stdin/stdout/stderr (no fork, no fd_inherit needed)
   pipe my $r, my $w or die;
   my $child = spawn3 0, fileno $w, 2, "/bin/echo", ["echo", "captured"];
   close $w;
   print <$r>; # "captured\n"
   waitpid $child, 0; # $child acts as the pid

   # ... and hold everything else back from the child
   my $child = spawn3 0, fileno $w, 2, "/bin/echo", ["echo", "hi"], { inherit => 0 };

=head1 DESCRIPTION

The purpose of this small (in scope and footprint) module is simple:
spawn a subprocess asynchronously as efficiently and/or fast as
possible. Basically the same as calling fork+exec (on POSIX), but
hopefully faster than those two syscalls.

Apart from fork overhead, this module also allows you to fork+exec
programs when otherwise you couldn't - for example, when you use POSIX
threads in your perl process then it generally isn't safe to call
fork from perl, but it is safe to use this module to execute external
processes.

If neither of these are problems for you, you can safely ignore this
module.

So when is fork+exec not fast enough, how can you do it faster, and why
would it matter?

Forking a process requires making a complete copy of a process. Even
thought almost every implementation only copies page tables and not the
memory itself, this is still not free. For example, on my 3.6GHz amd64
box, I can fork a 5GB process only twenty times a second. For a real-time
process that must meet stricter deadlines, this is too slow. For a busy
and big web server, starting CGI scripts might mean unacceptable overhead.

A workaround is to use C<vfork> - this function isn't very portable, but
it avoids the memory copy that C<fork> has to do. Some systems have an
optimised implementation of C<spawn>, and some systems have nothing.

This module tries to abstract these differences away.

As for what improvements to expect - on the 3.6GHz amd64 box that this
module was originally developed on, a 3MB perl process (basically just
perl + Proc::FastSpawn) takes 3.6s to run /bin/true 10000 times using
fork+exec, and only 2.6s when using vfork+exec. In a 22MB process, the
difference is already 5.0s vs 2.6s, and so on.

=head1 FUNCTIONS

All the following functions are currently exported by default.

=over 4

=cut

package Proc::FastSpawn;

# only used on WIN32 - maddeningly complex and doesn't even work
sub _quote {
   $_[0] = [@{ $_[0] }]; # make copy

   for (@{ $_[0] }) {
      if (/[\x01-\x20"]/) { # some sources say only space, "\t\n\v need to be escaped, microsoft says space and tab
         s/(\\*)"/$1$1\\"/g; # double + extra escape before "
         s/(\\+)$/$1$1/;     # just double at end
         $_ = '"' . $_ . '"';
      }
   }
}

package Proc::FastSpawn::Child;

# What spawn3/spawn3p return. It carries the pid and, on Windows, a duplicated
# process handle an event loop can wait on - Windows has no SIGCHLD, so a
# watcher needs the handle, and a handle obtained later by pid would race
# against pid reuse.
#
# It numifies and stringifies to the pid, so it can be used anywhere the plain
# pid used to be: waitpid, kill, comparisons, log messages and hash keys.

use overload
   '0+'     => sub { $_[0][0] },
   '""'     => sub { "$_[0][0]" },
   fallback => 1;

sub pid    { $_[0][0] }
sub handle { $_[0][1] }   # undef except on Windows

# Win32::Process spellings, so code written against one of those objects keeps
# working when handed a child instead. These are the names its C++ class really
# exposes, so an event loop that already knows how to watch a Win32::Process can
# be handed a child without changes.
*GetProcessID     = \&pid;
*GetProcessHandle = \&handle;

# The handle is ours (a duplicate), so closing it is independent of perl
# reaping the child and closing its own.
sub DESTROY {
   Proc::FastSpawn::_close_handle ($_[0][1])
      if defined $_[0][1];
}

package Proc::FastSpawn;

# Resolve a relative program path against the directory the child will run in,
# here in the parent, so that both ways of honouring "dir" agree. chdir-then-exec
# resolves a relative path against the new directory, while win32's
# lpCurrentDirectory sets the child's directory but still resolves the program
# against the *parent's*. Doing it once, before either, picks the first meaning
# everywhere. Only called when "dir" is given.
#
# A bare name with no separator is left alone for spawnp/spawn3p: that is a PATH
# lookup, which is execvp's own rule for telling the two apart.
use constant WIN32 => $^O eq "MSWin32";

sub _resolve {
   my ($path, $dir, $search) = @_;

   require File::Spec;

   return $path if File::Spec->file_name_is_absolute ($path);

   # index rather than a match: this is on the path of every spawn that gives a
   # directory. The backslash is only a separator on windows, where an absolute
   # path is caught above but a relative one - sub\helper.exe - would otherwise
   # look like a bare name and be sent to PATH instead of being resolved. On
   # POSIX it is an ordinary character in a filename, so testing for it there
   # would resolve "weird\name" against the directory where execvp, finding no
   # slash, would search PATH. The constant folds the test away off windows.
   return $path if $search
                   && index ($path, "/") < 0
                   && (!WIN32 || index ($path, "\\") < 0);

   File::Spec->rel2abs ($path, $dir)
}

BEGIN {
   $VERSION = '1.2.1';

   our @ISA = qw(Exporter);
   our @EXPORT = qw(spawn spawnp spawn3 spawn3p fd_inherit);
   require Exporter;

   require XSLoader;
   XSLoader::load (__PACKAGE__, $VERSION);
}

=item $pid = spawn $path, \@argv[, \@envp][, \%options]

Creates a new process and tries to make it execute C<$path>, with the given
arguments and optionally the given environment variables, similar to
calling fork + execv, or execve.

Returns the PID of the new process if successful. On any error, C<undef>
is currently returned. Failure to execution might or might not be reported
as C<undef>, or via a subprocess exit status of C<127>.

=item $pid = spawnp $file, \@argv[, \@envp][, \%options]

Like C<spawn>, but searches C<$file> in C<$ENV{PATH}> like the shell would
do.

=item $child = spawn3  $fd_in, $fd_out, $fd_err, $path, \@argv[, \@envp][, \%options]

=item $child = spawn3p $fd_in, $fd_out, $fd_err, $file, \@argv[, \@envp][, \%options]

Like C<spawn> / C<spawnp>, but additionally redirect the child's standard
input, output and error onto the given file descriptors before exec: each
C<$fd_*> is C<dup2>'d onto 0, 1 and 2 respectively (a value equal to its
target, e.g. C<0> for C<$fd_in>, is left untouched, so the child inherits
that descriptor unchanged). The source descriptors are then closed in the
child, so they do not leak into the executed program.

Unlike C<spawn> and C<spawnp>, these return a child object rather than a bare
PID -- see L</THE CHILD OBJECT>. It can be used anywhere the PID was, so the
difference does not normally show. On error they still return C<undef>.

Note that these are a superset of C<spawn> / C<spawnp>: passing a descriptor
that is already its own target (C<0>, C<1>, C<2>) produces no redirection at
all, so C<spawn3 0, 1, 2, ...> is exactly C<spawn ...> but with the child
object as the result.

On Windows these use C<CreateProcess> with C<STARTF_USESTDHANDLES>, which can
only hand the child the parent's own descriptors 0, 1 and 2. The three
descriptors are made inheritable for the duration of the call and put back
exactly as they were afterwards.

The child is created with the same creation flags the C<_spawn> family used,
which is to say none: it shares the console of whoever spawned it. See
C<Proc::FastSpawn::setOptions> if you want something else -- in particular if this might run
somewhere without a console of its own, where a console child would otherwise
be given a new one, window and all.

=item the options hash

All four functions take an optional hash reference as their last argument. It
may be given in place of C<\@envp> as well as after it, since an option hash
and an environment list are told apart by type. Unknown keys are a fatal
error, so a misspelling does not pass silently.

Only things that mean something on every platform go here, so a spawn call
never has to be written differently for one operating system. Settings that
are inherently platform-specific live in C<Proc::FastSpawn::setOptions>
instead.

There is currently one option:

=over 4

=item inherit => $bool

Whether the child gets the file descriptors above 0, 1 and 2 that this process
has open. The default is true, which is what these functions have always done.

With C<< inherit => 0 >> the child is held to its three standard descriptors.
On Windows the others are left out of the descriptor table handed to the child
and, where the operating system offers it, out of the inherited handle list as
well. On POSIX they are marked close-on-exec for the duration of the spawn and
put back as they were afterwards; the three C<spawn3> redirects are unaffected,
as C<dup2> clears that flag on its target.

This is a blunt instrument: it is "everything or nothing but 0/1/2", not a
per-descriptor choice. For that, see C<fd_inherit>.

=item dir => $path

The directory the child runs in. The default is to inherit the parent process's.
How a bad directory is reported differs by platform - see below.

If the program path given to the spawn is relative, it is resolved against this
directory B<before the spawn>, in the parent process. On POSIX the directory is
changed in the child before C<exec>, so a relative program would resolve against
the new directory, while Windows sets the child's directory but still resolves
the program against the I<parent> process's. Resolving once, here, means both
mean the same thing. For C<spawnp> and C<spawn3p>, a bare name with no directory
separator is left alone, since that is a C<PATH> lookup rather than a path - the
same rule C<execvp> uses.

B<Failure reporting depends on the platform>. The usual case - a directory that is
not there - is the one that differs. Where the directory is applied by the
operating system as part of creating the process, failing to apply it fails the
spawn, so these functions return C<undef> with C<$!> set, as for any other
failure: that is Windows, and POSIX systems where C<posix_spawn> is used and
provides C<posix_spawn_file_actions_addchdir_np>.

Everywhere else - which is most systems, including Linux - the directory is
changed by the child itself, after the process already exists and the parent
already holds its PID. There is no way to report it back: the only signal is the
child's exit status. It exits B<126> when the directory could not be changed to,
as against B<127> for a program that could not be executed, following the shell
convention, so the two can at least be told apart.

On a system that has neither mechanism, C<dir> croaks rather than being quietly
ignored.

=back

=item %old = Proc::FastSpawn::setOptions key => $value, ...

Sets process-wide defaults for how children are created, and returns the
settings as they were before the call, as a list of key/value pairs suitable
for handing straight back. Called with no arguments it changes nothing and
just reports the current settings.

This is the only call in this module that is about one operating system, and
deliberately so: the per-call option hash stays portable, and anything that
only makes sense on Windows is set here, once, by a program that knows how it
is going to be run.

It is not exported: this changes behaviour for the whole interpreter, so it
reads better spelled out.

   my %old = Proc::FastSpawn::setOptions (create_no_window => 1);
   ...
   Proc::FastSpawn::setOptions (%old);     # put it back

All of these name C<CreateProcess> creation flags and do nothing outside
Windows, but the names are known everywhere, so a misspelling is caught while
developing on a platform where the option has no effect. Unknown keys, an odd
number of arguments, and combinations C<CreateProcess> would reject are all
fatal; a call that is rejected leaves the settings untouched rather than
applying half of them.

All default to false, which gives the C<dwCreateFlags> of C<0> that the
C<_spawn> family passed and that this module has always produced.

=over 4

=item create_no_window => $bool

C<CREATE_NO_WINDOW>. The child gets a console of its own with no window on it.
Without this the child shares the console of whoever spawned it, and if that
process has none -- C<wperl>, a service, any GUI program -- Windows gives a
console child a new console, window and all. Set this if nothing of yours
should ever put something on the screen.

Note that the child then no longer shares your console, so anything that cares
about that -- C<CONIN$>, C<GetConsoleWindow>, being in your Ctrl-C group --
sees a different world. Ordinary standard input, output and error are
unaffected.

=item detached_process => $bool

C<DETACHED_PROCESS>. The child gets no console at all. It can still make one
for itself with C<AllocConsole>.

=item create_new_console => $bool

C<CREATE_NEW_CONSOLE>. The child gets a new console with a window, which will
appear on the screen. Cannot be combined with C<detached_process>.

=item create_new_process_group => $bool

C<CREATE_NEW_PROCESS_GROUP>. The child starts a new process group, so a Ctrl-C
in your console does not reach it.

=back

=item fd_inherit $fileno[, $on]

File descriptors can be inherited by the spawned processes or not. This is
decided on a per file descriptor basis. This module does nothing to any
preexisting handles, but with this call, you can change the state of a
single file descriptor to either be inherited (C<$on> is true or missing)
or not C<$on> is false).

Free portability pro-tip: it seems native win32 perls ignore $^F and set
all file handles to be inherited by default - but this function can switch
it off.

=back

=head1 THE CHILD OBJECT

C<spawn3> and C<spawn3p> return a C<Proc::FastSpawn::Child>. It overloads C<0+>
and C<""> to the PID, so it can be used wherever the plain PID could be --
C<waitpid>, C<kill>, comparisons, hash keys, log messages -- and code that only
wants a PID needs no changes.

It exists because a PID is not everything a caller may need. Windows has no
C<SIGCHLD>, so an event loop that wants to know when a child exits has to wait
on the process handle; and obtaining that handle later, from the PID, races
against PID reuse and fails outright once the child has been reaped. Handing it
back together with the PID is the only point at which it can be done safely.

=over 4

=item $child->pid, $child->GetProcessID

The process ID, as returned by C<spawn>.

=item $child->handle, $child->GetProcessHandle

The process handle, where the platform has such a thing, as a plain integer.

On Windows this is a duplicate of the process handle, suitable for
C<WaitForSingleObject> / C<WaitForMultipleObjects> and C<GetExitCodeProcess>.
On POSIX systems it is C<undef>, there being nothing a waiter needs beyond the
PID.

The handle is owned by the object and closed when the last reference to it goes
away, independently of whether the child has been reaped.

=back

The C<GetProcessID> and C<GetProcessHandle> spellings are those used by
C<Win32::Process>, so that a child can be handed to code already written to
watch one of those objects.

=head1 PORTABILITY NOTES

On POSIX systems, this module currently calls vfork+exec, spawn, or
fork+exec, depending on the platform. If your platform has a good vfork or
spawn but is misdetected and falls back to slow fork+exec, drop Marc a note.

On win32, C<CreateProcess> is used, and the module tries hard to patch the
new process into perl's internal pid table, so the pid returned should work
with other Perl functions such as waitpid. It carries over the descriptor
table the C runtime passes to a child, so a descriptor the child inherits is
reachable there by number and not only as one of its standard handles. Also,
win32 doesn't have a meaningful way to quote arguments containing
"special" characters, so this module tries it's best to quote those
strings itself. Other typical platform limitations (such as being able to
only have 64 or so subprocesses) are not worked around.
itself: a spawned child occupies a slot in perl's table until it is reaped, and
on win32 only C<waitpid>, C<wait> and C<kill> drain it -- there is no C<SIGCHLD>
and nothing reaps in the background. After 64 unreaped children, spawning fails
with C<EAGAIN> and does not recover. If you watch children by their handle
rather than by reaping them, reap them anyway.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

