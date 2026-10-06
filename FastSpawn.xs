/* GetProcessId is XP and up, which means in all supported versions */
/* but older SDK's might need this */
#define _WIN32_WINNT NTDDI_WINXP

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdio.h>

#ifdef WIN32

  /* perl probably did this already */
  #include <windows.h>

#else

  #include <errno.h>
  #include <fcntl.h>
  #include <unistd.h>

  /* openbsd seems to have a buggy vfork (what would you expect), */
  /* while others might implement vfork as fork in older versions, which is fine */
  #if __linux || __FreeBSD__ || __NetBSD__ || __sun
    #define USE_VFORK 1
  #endif

  #if !USE_VFORK
    #if _POSIX_SPAWN >= 200809L
      #define USE_SPAWN 1
      #include <spawn.h>
    #else
      #define vfork() fork()
    #endif
  #endif

#endif

static char *const *
array_to_cvec (SV *sv)
{
  AV *av;
  int n, i;
  char **cvec;

  if (!SvROK (sv) || SvTYPE (SvRV (sv)) != SVt_PVAV)
    croak ("expected a reference to an array of argument/environment strings");

  av = (AV *)SvRV (sv);
  n = av_len (av) + 1;
  cvec = (char **)SvPVX (sv_2mortal (NEWSV (0, sizeof (char *) * (n + 1))));

  for (i = 0; i < n; ++i)
    cvec [i] = SvPVbyte_nolen (*av_fetch (av, i, 1));

  cvec [n] = 0;

  return cvec;
}

#ifdef WIN32

  #include <io.h> /* _get_osfhandle */

  /* CreateProcess wants one command line, not a vector. argv has already been
   * through Proc::FastSpawn::_quote (see the INIT block), so the elements are
   * quoted already and only have to be joined. */
  static char *
  w32_cmdline (pTHX_ char *const *cargv)
  {
    size_t len = 1;
    char *const *p;
    char *cmd, *q;

    for (p = cargv; *p; ++p)
      len += strlen (*p) + 1;

    Newx (cmd, len, char);

    q = cmd;
    for (p = cargv; *p; ++p)
      {
        size_t n = strlen (*p);

        if (q != cmd)
          *q++ = ' ';

        memcpy (q, *p, n);
        q += n;
      }
    *q = 0;

    return cmd;
  }

  /* ... and one NUL-separated, double-NUL-terminated block, not a vector. */
  static char *
  w32_envblock (pTHX_ char *const *cenvp)
  {
    size_t len = 2; /* the two terminating NULs, for an empty block too */
    char *const *p;
    char *block, *q;

    for (p = cenvp; *p; ++p)
      len += strlen (*p) + 1;

    Newx (block, len, char);

    q = block;
    for (p = cenvp; *p; ++p)
      {
        size_t n = strlen (*p) + 1;

        memcpy (q, *p, n);
        q += n;
      }
    *q = 0;

    return block;
  }

  /* PROC_THREAD_ATTRIBUTE_HANDLE_LIST is Vista and up. Without it,
   * CreateProcess with bInheritHandles gives the child *every* inheritable
   * handle rather than just the three named here, which is why callers have
   * had to mark unrelated descriptors non-inheritable around a spawn. Resolve
   * it at runtime, so this still runs on XP - where that is simply the old
   * behaviour, as it has always been. */
  #ifdef EXTENDED_STARTUPINFO_PRESENT
    #define HAVE_W32_ATTRLIST 1

    typedef BOOL (WINAPI *w32_attr_init_t)   (LPPROC_THREAD_ATTRIBUTE_LIST, DWORD, DWORD, PSIZE_T);
    typedef BOOL (WINAPI *w32_attr_update_t) (LPPROC_THREAD_ATTRIBUTE_LIST, DWORD, DWORD_PTR, PVOID, SIZE_T, PVOID, PSIZE_T);
    typedef VOID (WINAPI *w32_attr_delete_t) (LPPROC_THREAD_ATTRIBUTE_LIST);

    static w32_attr_init_t   w32_attr_init;
    static w32_attr_update_t w32_attr_update;
    static w32_attr_delete_t w32_attr_delete;

    static void
    w32_attr_resolve (void)
    {
      static int done;
      HMODULE k32;

      if (done)
        return;

      done = 1;

      if (!(k32 = GetModuleHandleA ("kernel32.dll")))
        return;

      w32_attr_init   = (w32_attr_init_t)   (void (*)(void))GetProcAddress (k32, "InitializeProcThreadAttributeList");
      w32_attr_update = (w32_attr_update_t) (void (*)(void))GetProcAddress (k32, "UpdateProcThreadAttribute");
      w32_attr_delete = (w32_attr_delete_t) (void (*)(void))GetProcAddress (k32, "DeleteProcThreadAttributeList");

      /* all or nothing */
      if (!w32_attr_init || !w32_attr_update || !w32_attr_delete)
        w32_attr_init = 0;
    }
  #endif

  /* CreateProcess reports through GetLastError; give errno something useful
   * too, since that is what the documented interface talks about. */
  static void
  w32_set_errno (void)
  {
    switch (GetLastError ())
      {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:     errno = ENOENT; break;
        case ERROR_ACCESS_DENIED:      errno = EACCES; break;
        case ERROR_NOT_ENOUGH_MEMORY:
        case ERROR_OUTOFMEMORY:        errno = ENOMEM; break;
        case ERROR_BAD_EXE_FORMAT:     errno = ENOEXEC; break;
        default:                       errno = EINVAL; break;
      }
  }

#endif

/* Build what spawn3/spawn3p hand back: a Proc::FastSpawn::Child carrying the
 * pid and, on Windows, a duplicated process handle. It overloads 0+ and "" to
 * the pid, so callers that just want a pid are unaffected. */
static SV *
new_child (pTHX_ IV pid, void *handle)
{
  AV *av = newAV ();

  av_push (av, newSViv (pid));
  av_push (av, handle ? newSVuv (PTR2UV (handle)) : newSV (0));

  return sv_bless (newRV_noinc ((SV *)av),
                   gv_stashpv ("Proc::FastSpawn::Child", GV_ADD));
}

MODULE = Proc::FastSpawn		PACKAGE = Proc::FastSpawn

PROTOTYPES: ENABLE

BOOT:
#ifndef WIN32
        cv_undef (get_cv ("Proc::FastSpawn::_quote", 0));
#endif

long
spawn (const char *path, SV *argv, SV *envp = &PL_sv_undef)
	ALIAS:
        spawnp = 1
        INIT:
{
#ifdef WIN32
        if (w32_num_children >= MAXIMUM_WAIT_OBJECTS)
          {
            errno = EAGAIN;
            XSRETURN_UNDEF;
          }

        argv = sv_2mortal (newSVsv (argv));
        PUSHMARK (SP);
        XPUSHs (argv);
        PUTBACK;
        call_pv ("Proc::FastSpawn::_quote", G_VOID | G_DISCARD);
        SPAGAIN;
#endif
}
	CODE:
{
	extern char **environ;
	char *const *cargv =               array_to_cvec (argv);
	char *const *cenvp = SvOK (envp) ? array_to_cvec (envp) : environ;
        intptr_t pid;

        fflush (0);
#ifdef WIN32
        pid = (ix ? _spawnvpe : _spawnve) (_P_NOWAIT, path, cargv, cenvp);

        if (pid == -1)
          XSRETURN_UNDEF;

        /* do it like perl, dadadoop dadadoop */
        w32_child_handles [w32_num_children] = (HANDLE)pid;
        pid = GetProcessId ((HANDLE)pid); /* get the real pid, unfortunately, requires wxp or newer */
        w32_child_pids [w32_num_children] = pid;
        ++w32_num_children;
#elif USE_SPAWN
        {
          pid_t xpid;

          errno = (ix ? posix_spawnp : posix_spawn) (&xpid, path, 0, 0, cargv, cenvp);

          if (errno)
            XSRETURN_UNDEF;

          pid = xpid;
        }
#else
        pid = (ix ? fork : vfork) ();

        if (pid < 0)
          XSRETURN_UNDEF;

        if (pid == 0)
          {
            if (ix)
              {
                environ = (char **)cenvp;
                execvp (path, cargv);
              }
            else
              execve (path, cargv, cenvp);

            _exit (127);
          }
#endif

        RETVAL = pid;
}
	OUTPUT: RETVAL

void
spawn3 (int fd_in, int fd_out, int fd_err, const char *path, SV *argv, SV *envp = &PL_sv_undef)
	ALIAS:
        spawn3p = 1
        INIT:
{
#ifdef WIN32
        if (w32_num_children >= MAXIMUM_WAIT_OBJECTS)
          {
            errno = EAGAIN;
            XSRETURN_UNDEF;
          }

        argv = sv_2mortal (newSVsv (argv));
        PUSHMARK (SP);
        XPUSHs (argv);
        PUTBACK;
        call_pv ("Proc::FastSpawn::_quote", G_VOID | G_DISCARD);
        SPAGAIN;
#endif
}
	PPCODE:
{
	extern char **environ;
	char *const *cargv =               array_to_cvec (argv);
	char *const *cenvp = SvOK (envp) ? array_to_cvec (envp) : environ;
        intptr_t pid;
        void *hchild = 0;
        int rfd [3];
        int i;

        rfd [0] = fd_in; rfd [1] = fd_out; rfd [2] = fd_err;

        fflush (0);
#ifdef WIN32
        {
          STARTUPINFOEXA six;
          PROCESS_INFORMATION pi;
          HANDLE hstd [3], hlist [3], hdup;
          DWORD oldflags [3];
          int have_old [3];
          int nlist = 0, k;
          char *cmdline, *envblock = 0, *attrbuf = 0;
          char progbuf [MAX_PATH];
          const char *appname = path;
          DWORD flags = CREATE_NO_WINDOW;
          BOOL ok;

          /* Resolve the three descriptors. One that is already its own target
           * means "inherit ours", exactly as on POSIX. */
          for (i = 0; i < 3; ++i)
            {
              int fd = rfd [i] >= 0 ? rfd [i] : i;

              hstd [i] = (HANDLE)_get_osfhandle (fd);

              if (hstd [i] == INVALID_HANDLE_VALUE)
                {
                  errno = EBADF;
                  XSRETURN_UNDEF;
                }
            }

          /* STARTF_USESTDHANDLES only means anything for inheritable handles.
           * Remember what each was so the parent is left exactly as found -
           * duplicates collapse, as the same handle must not be listed twice. */
          for (i = 0; i < 3; ++i)
            {
              int seen = 0;

              for (k = 0; k < nlist; ++k)
                if (hlist [k] == hstd [i]) { seen = 1; break; }

              if (seen)
                continue;

              have_old [nlist] = GetHandleInformation (hstd [i], &oldflags [nlist]) ? 1 : 0;
              SetHandleInformation (hstd [i], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
              hlist [nlist++] = hstd [i];
            }

          ZeroMemory (&six, sizeof (six));
          six.StartupInfo.cb          = sizeof (STARTUPINFOA);
          six.StartupInfo.dwFlags     = STARTF_USESTDHANDLES;
          six.StartupInfo.hStdInput   = hstd [0];
          six.StartupInfo.hStdOutput  = hstd [1];
          six.StartupInfo.hStdError   = hstd [2];

          #ifdef HAVE_W32_ATTRLIST
          w32_attr_resolve ();

          if (w32_attr_init)
            {
              SIZE_T attrsize = 0;

              /* the sizing call is expected to fail, it only sets attrsize */
              w32_attr_init (0, 1, 0, &attrsize);
              Newx (attrbuf, attrsize, char);

              if (w32_attr_init ((LPPROC_THREAD_ATTRIBUTE_LIST)attrbuf, 1, 0, &attrsize)
                  && w32_attr_update ((LPPROC_THREAD_ATTRIBUTE_LIST)attrbuf, 0,
                                      PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                      hlist, nlist * sizeof (HANDLE), 0, 0))
                {
                  six.StartupInfo.cb      = sizeof (STARTUPINFOEXA);
                  six.lpAttributeList     = (LPPROC_THREAD_ATTRIBUTE_LIST)attrbuf;
                  flags                  |= EXTENDED_STARTUPINFO_PRESENT;
                }
              else
                {
                  Safefree (attrbuf);
                  attrbuf = 0;
                }
            }
          #endif

          cmdline = w32_cmdline (aTHX_ cargv);

          if (SvOK (envp))
            envblock = w32_envblock (aTHX_ cenvp);

          if (ix)
            {
              /* spawn3p: resolve through PATH ourselves rather than letting
               * CreateProcess parse it out of the command line, which would
               * search for argv[0] instead of the file we were given. */
              DWORD n = SearchPathA (0, path, ".exe", sizeof (progbuf), progbuf, 0);

              appname = (n > 0 && n < sizeof (progbuf)) ? progbuf : 0;
            }

          ok = CreateProcessA ((char *)appname, cmdline, 0, 0, TRUE, flags,
                               envblock, 0, &six.StartupInfo, &pi);

          /* put the parent's handles back the way they were */
          for (k = 0; k < nlist; ++k)
            if (have_old [k])
              SetHandleInformation (hlist [k], HANDLE_FLAG_INHERIT,
                                    oldflags [k] & HANDLE_FLAG_INHERIT);

          #ifdef HAVE_W32_ATTRLIST
          if (attrbuf)
            {
              w32_attr_delete ((LPPROC_THREAD_ATTRIBUTE_LIST)attrbuf);
              Safefree (attrbuf);
            }
          #endif
          Safefree (cmdline);
          if (envblock)
            Safefree (envblock);

          if (!ok)
            {
              w32_set_errno ();
              XSRETURN_UNDEF;
            }

          CloseHandle (pi.hThread);

          /* Same bookkeeping spawn does, so waitpid and $? work on the pid. */
          w32_child_handles [w32_num_children] = pi.hProcess;
          w32_child_pids    [w32_num_children] = pi.dwProcessId;
          ++w32_num_children;

          /* The caller gets its own reference: perl closes the one above when
           * the child is reaped, and a handle being waited on must not vanish
           * underneath the waiter. Not inheritable, or it would leak into every
           * subsequent child spawned with handle inheritance on. */
          if (!DuplicateHandle (GetCurrentProcess (), pi.hProcess,
                                GetCurrentProcess (), &hdup,
                                0, FALSE, DUPLICATE_SAME_ACCESS))
            hdup = 0;

          hchild = hdup;
          pid    = pi.dwProcessId;
        }
#elif USE_SPAWN
        {
          pid_t xpid;
          posix_spawn_file_actions_t fa;

          posix_spawn_file_actions_init (&fa);

          /* redirect fd_in/out/err onto 0/1/2 */
          for (i = 0; i < 3; ++i)
            if (rfd [i] >= 0 && rfd [i] != i)
              posix_spawn_file_actions_adddup2 (&fa, rfd [i], i);

          /* close the (duplicated) source fds; skip duplicate values so we do
             not close the same fd twice (which would fail the spawn). */
          for (i = 0; i < 3; ++i)
            if (rfd [i] > 2)
              {
                int seen = 0, k;
                for (k = 0; k < i; ++k)
                  if (rfd [k] == rfd [i]) { seen = 1; break; }
                if (!seen)
                  posix_spawn_file_actions_addclose (&fa, rfd [i]);
              }

          errno = (ix ? posix_spawnp : posix_spawn) (&xpid, path, &fa, 0, cargv, cenvp);

          posix_spawn_file_actions_destroy (&fa);

          if (errno)
            XSRETURN_UNDEF;

          pid = xpid;
        }
#else
        pid = (ix ? fork : vfork) ();

        if (pid < 0)
          XSRETURN_UNDEF;

        if (pid == 0)
          {
            /* Child. Only async-signal-safe calls here (vfork-safe): dup2/close
               then exec. dup2 also clears close-on-exec on the targets. */
            for (i = 0; i < 3; ++i)
              if (rfd [i] >= 0 && rfd [i] != i)
                if (dup2 (rfd [i], i) < 0)
                  _exit (127);

            for (i = 0; i < 3; ++i)
              if (rfd [i] > 2)
                {
                  int seen = 0, k;
                  for (k = 0; k < i; ++k)
                    if (rfd [k] == rfd [i]) { seen = 1; break; }
                  if (!seen)
                    close (rfd [i]);
                }

            if (ix)
              {
                environ = (char **)cenvp;
                execvp (path, cargv);
              }
            else
              execve (path, cargv, cenvp);

            _exit (127);
          }
#endif

        /* ST(0) held fd_in, which has long been copied into a C int */
        ST (0) = sv_2mortal (new_child (aTHX_ pid, hchild));
        XSRETURN (1);
}

void
_close_handle (UV handle)
	CODE:
{
#ifdef WIN32
        if (handle)
          CloseHandle ((HANDLE)handle);
#else
        PERL_UNUSED_VAR (handle);
#endif
}

void
fd_inherit (int fd, int on = 1)
	CODE:
#ifdef WIN32
        SetHandleInformation ((HANDLE)_get_osfhandle (fd), HANDLE_FLAG_INHERIT, on ? HANDLE_FLAG_INHERIT : 0);
#else
        fcntl (fd, F_SETFD, on ? 0 : FD_CLOEXEC);
#endif

