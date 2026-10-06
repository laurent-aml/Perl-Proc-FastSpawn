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

/* Process-wide CreateProcess defaults, set through Proc::FastSpawn::setOptions.
 *
 * Nothing is on to begin with, which is the dwCreateFlags of 0 that _spawnve
 * passed and so what this module has always produced. The names are known on
 * every platform even though only win32 acts on them, so a misspelling is
 * caught when developing somewhere the option does nothing. */
#ifndef WIN32
  #define CREATE_NO_WINDOW         0
  #define CREATE_NEW_CONSOLE       0
  #define DETACHED_PROCESS         0
  #define CREATE_NEW_PROCESS_GROUP 0
#endif

enum {
  OPT_NO_WINDOW,
  OPT_NEW_CONSOLE,
  OPT_DETACHED,
  OPT_NEW_GROUP,
  OPT_COUNT
};

#define SPAWN_OPT(name, flag) { name, sizeof (name) - 1, flag }

static const struct {
  const char   *name;
  STRLEN        len;
  unsigned long flag;
} spawn_opt [OPT_COUNT] = {
  SPAWN_OPT ("create_no_window",         CREATE_NO_WINDOW        ),
  SPAWN_OPT ("create_new_console",       CREATE_NEW_CONSOLE      ),
  SPAWN_OPT ("detached_process",         DETACHED_PROCESS        ),
  SPAWN_OPT ("create_new_process_group", CREATE_NEW_PROCESS_GROUP)
};

static int spawn_opt_on [OPT_COUNT];

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

  /* The CRT's inherited descriptor block, for STARTUPINFO.lpReserved2.
   *
   * CreateProcess passes inheritable HANDLEs to the child, but nothing tells
   * the child's CRT which descriptor number each one should be, so a child
   * cannot reach them as fds - "open '<&3'" fails. _spawnve passes this block,
   * which is how that works today; since we no longer go through _spawnve (it
   * offers no way to ask for CREATE_NO_WINDOW), we build it ourselves.
   *
   * Layout is a CRT implementation detail rather than documented API, but it
   * has been the same since msvcrt and is still what UCRT reads: an int count,
   * then count flag bytes, then count HANDLEs.
   *
   * A descriptor whose handle is not inheritable is passed as "not open"
   * rather than with its handle. _spawnve hands the handle over regardless,
   * and the child's startup then faults on a handle it was never given, which
   * is what makes fd_inherit($fd, 0) kill the child instead of merely hiding
   * the descriptor from it. */
  #define W32_FOPEN      0x01
  #define W32_FPIPE      0x08
  #define W32_FDEV       0x40

  /* How far up the descriptor table to look for things to pass on. */
  #ifndef W32_MAX_FD
    #define W32_MAX_FD 1024
  #endif

  static char *
  w32_fdblock (pTHX_ DWORD *sizep, HANDLE const *stdh, int inherit_all,
               int const *omit)
  {
    int i, count = 3, saved_errno = errno;
    char *blk, *flags;
    HANDLE *handles;

    /* _get_osfhandle sets EBADF for every descriptor that is not open, and the
     * scan below asks about a great many. Leaving that behind would have a
     * caller inspecting $! after a spawn that succeeded read "bad file
     * descriptor", so put errno back as we found it. */
    if (inherit_all)
      for (i = 3; i < W32_MAX_FD; ++i)
        if ((HANDLE)_get_osfhandle (i) != INVALID_HANDLE_VALUE)
          count = i + 1;

    errno = saved_errno;

    *sizep = (DWORD)(sizeof (int) + count * (sizeof (char) + sizeof (HANDLE)));
    Newxz (blk, *sizep, char);

    *(int *)blk = count;
    flags       = blk + sizeof (int);
    handles     = (HANDLE *)(flags + count);

    for (i = 0; i < count; ++i)
      {
        HANDLE h = i < 3 && stdh ? stdh [i] : (HANDLE)_get_osfhandle (i);
        DWORD hf, type;

        /* A descriptor that was redirected onto 0/1/2 is gone from the child,
         * as it is on POSIX, where the file actions close it. Leaving it would
         * also hand the same HANDLE out under two numbers, and closing either
         * would then invalidate the other. */
        if (i > 2 && omit
            && (i == omit [0] || i == omit [1] || i == omit [2]))
          {
            flags   [i] = 0;
            handles [i] = INVALID_HANDLE_VALUE;
            continue;
          }

        /* unopened, or one the child will not be given: say "not open" */
        if (h == INVALID_HANDLE_VALUE || h == 0
            || !GetHandleInformation (h, &hf)
            || !(hf & HANDLE_FLAG_INHERIT))
          {
            flags   [i] = 0;
            handles [i] = INVALID_HANDLE_VALUE;
            continue;
          }

        flags [i] = W32_FOPEN;

        type = GetFileType (h);
        if (type == FILE_TYPE_CHAR)      flags [i] |= W32_FDEV;
        else if (type == FILE_TYPE_PIPE) flags [i] |= W32_FPIPE;

        handles [i] = h;
      }

    return blk;
  }

  /* The dwCreateFlags setOptions has asked for. */
  static DWORD
  w32_create_flags (void)
  {
    DWORD flags = 0;
    int i;

    for (i = 0; i < OPT_COUNT; ++i)
      if (spawn_opt_on [i])
        flags |= (DWORD)spawn_opt [i].flag;

    return flags;
  }

  /* One CreateProcess for all four entry points.
   *
   * stdh, when given, is the three handles the child should see as 0/1/2;
   * without it the child gets the parent's own. inherit_all asks for the
   * historical behaviour - every inheritable handle goes to the child - and
   * when it is off the child is held to 0/1/2 alone.
   *
   * Returns 1 and fills *pidp/*hprocp, or 0 with errno set. */
  static int
  w32_spawn (pTHX_ const char *path, int search,
             char *const *cargv, char *const *cenvp, int have_envp,
             HANDLE const *stdh, int inherit_all,
             int const *omit,
             DWORD *pidp, HANDLE *hprocp)
  {
    STARTUPINFOEXA six;
    PROCESS_INFORMATION pi;
    HANDLE hstd [3], hlist [3];
    DWORD oldflags [3], fdblocksize;
    int have_old [3];
    int nlist = 0, i, k;
    char *cmdline, *envblock = 0, *attrbuf = 0, *fdblock;
    char progbuf [MAX_PATH];
    const char *appname = path;
    DWORD flags = w32_create_flags ();
    BOOL ok;

    for (i = 0; i < 3; ++i)
      {
        hstd [i] = stdh ? stdh [i] : (HANDLE)_get_osfhandle (i);

        /* STARTF_USESTDHANDLES has to name all three, so a redirect cannot
         * go ahead with one of them missing. Without it a descriptor the
         * parent has closed simply stays closed in the child, which is what
         * _spawnve did and so what spawn/spawnp have always done. */
        if (hstd [i] == INVALID_HANDLE_VALUE && stdh)
          {
            errno = EBADF;
            return 0;
          }
      }

    /* A handle the child is to be given has to be inheritable, both for
     * STARTF_USESTDHANDLES and for the descriptor block, which reports a
     * handle that is not inheritable as not open. Remember what each was so
     * the parent is left exactly as found - duplicates collapse, as the same
     * handle must not be listed twice. */
    for (i = 0; i < 3; ++i)
      {
        int seen = 0;

        if (hstd [i] == INVALID_HANDLE_VALUE)
          continue;

        for (k = 0; k < nlist; ++k)
          if (hlist [k] == hstd [i]) { seen = 1; break; }

        if (seen)
          continue;

        have_old [nlist] = GetHandleInformation (hstd [i], &oldflags [nlist]) ? 1 : 0;
        SetHandleInformation (hstd [i], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        hlist [nlist++] = hstd [i];
      }

    ZeroMemory (&six, sizeof (six));
    six.StartupInfo.cb = sizeof (STARTUPINFOA);

    /* Only when something is really being redirected. spawn/spawnp leave the
     * standard handles alone, as _spawnve did: the child picks them up from
     * the descriptor block and from what it inherits. */
    if (stdh)
      {
        six.StartupInfo.dwFlags     = STARTF_USESTDHANDLES;
        six.StartupInfo.hStdInput   = hstd [0];
        six.StartupInfo.hStdOutput  = hstd [1];
        six.StartupInfo.hStdError   = hstd [2];
      }

    /* what lets the child reach these as numbered descriptors */
    fdblock = w32_fdblock (aTHX_ &fdblocksize, hstd, inherit_all, omit);
    six.StartupInfo.lpReserved2 = (LPBYTE)fdblock;
    six.StartupInfo.cbReserved2 = (WORD)fdblocksize;

    #ifdef HAVE_W32_ATTRLIST
    /* Only when the caller asked to keep the rest back: with inheritance left
     * open there is nothing to restrict, and the list would cost a heap
     * allocation per spawn for nothing. */
    if (!inherit_all)
      {
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
      }
    #endif

    cmdline = w32_cmdline (aTHX_ cargv);

    if (have_envp)
      envblock = w32_envblock (aTHX_ cenvp);

    if (search)
      {
        /* resolve through PATH ourselves rather than letting CreateProcess
         * parse it out of the command line, which would search for argv[0]
         * instead of the file we were given */
        DWORD n = SearchPathA (0, path, ".exe", sizeof (progbuf), progbuf, 0);

        if (!n || n >= sizeof (progbuf))
          {
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
            Safefree (fdblock);
            Safefree (cmdline);
            if (envblock)
              Safefree (envblock);

            errno = ENOENT;
            return 0;
          }

        appname = progbuf;
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
    Safefree (fdblock);
    Safefree (cmdline);
    if (envblock)
      Safefree (envblock);

    if (!ok)
      {
        w32_set_errno ();
        return 0;
      }

    CloseHandle (pi.hThread);

    *pidp   = pi.dwProcessId;
    *hprocp = pi.hProcess;

    return 1;
  }

#endif

#ifndef WIN32

  /* Keep everything above 0/1/2 back from the child by marking it
   * close-on-exec for the duration of the spawn, then putting the flags back.
   * There is no portable file action for "close the rest", and doing it in the
   * child is not open to us on the vfork path, where only async-signal-safe
   * calls are allowed and the memory is still shared with us.
   *
   * dup2 clears close-on-exec on its target, so the three descriptors spawn3
   * redirects onto 0/1/2 come through this untouched. */
  #ifndef MAX_FD_SCAN
    #define MAX_FD_SCAN 1024
  #endif

  static int
  cloexec_hold (pTHX_ int **savep)
  {
    int i, n = 0, saved_errno = errno;
    int *save;

    Newx (save, MAX_FD_SCAN, int);

    for (i = 3; i < MAX_FD_SCAN; ++i)
      {
        int f = fcntl (i, F_GETFD);

        if (f < 0 || (f & FD_CLOEXEC))
          continue;

        if (fcntl (i, F_SETFD, f | FD_CLOEXEC) == 0)
          save [n++] = i;
      }

    /* F_GETFD sets EBADF for every descriptor that is not open, and we just
     * asked about a great many. A caller reading $! after a spawn that worked
     * should not find "bad file descriptor" waiting there. */
    errno = saved_errno;

    *savep = save;
    return n;
  }

  static void
  cloexec_release (pTHX_ int *save, int n)
  {
    int i, saved_errno = errno;

    for (i = 0; i < n; ++i)
      {
        int f = fcntl (save [i], F_GETFD);

        if (f >= 0)
          fcntl (save [i], F_SETFD, f & ~FD_CLOEXEC);
      }

    errno = saved_errno;
    Safefree (save);
  }

#endif

/* The optional trailing option hash.
 *
 * envp may be left out and the hash passed in its place: an option hash and an
 * environment list are told apart by type, so there is nothing to disambiguate.
 * When that happens envp is reset to undef, which means "inherit ours".
 *
 * Returns the value of "inherit", which defaults on. */
static int
spawn_options (pTHX_ SV **envpp, SV *opts)
{
  SV *hash = 0;
  HV *hv;
  HE *he;
  int inherit = 1;

  if (SvROK (*envpp) && SvTYPE (SvRV (*envpp)) == SVt_PVHV)
    {
      hash   = *envpp;
      *envpp = &PL_sv_undef;
    }

  if (SvOK (opts))
    {
      if (hash)
        croak ("Proc::FastSpawn: options given twice");

      if (!SvROK (opts) || SvTYPE (SvRV (opts)) != SVt_PVHV)
        croak ("Proc::FastSpawn: options must be a hash reference");

      hash = opts;
    }

  if (!hash)
    return inherit;

  hv = (HV *)SvRV (hash);

  hv_iterinit (hv);
  while ((he = hv_iternext (hv)))
    {
      STRLEN len;
      const char *key = HePV (he, len);

      if (len == 7 && memEQ (key, "inherit", 7))
        inherit = SvTRUE (HeVAL (he));
      else
        croak ("Proc::FastSpawn: unknown option %.*s", (int)len, key);
    }

  return inherit;
}

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
spawn (const char *path, SV *argv, SV *envp = &PL_sv_undef, SV *opts = &PL_sv_undef)
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
        int inherit = spawn_options (aTHX_ &envp, opts);
	char *const *cargv =               array_to_cvec (argv);
	char *const *cenvp = SvOK (envp) ? array_to_cvec (envp) : environ;
        intptr_t pid;

        fflush (0);
#ifdef WIN32
        {
          DWORD wpid;
          HANDLE hproc;

          /* Not _spawnve any more: it gives no way to ask for CREATE_NO_WINDOW,
           * so a console child spawned from a perl without a console of its own
           * - wperl, a service - popped a console window. Going through
           * CreateProcess means carrying the descriptor block ourselves, which
           * is what w32_fdblock is for. */
          if (!w32_spawn (aTHX_ path, ix, cargv, cenvp, SvOK (envp),
                          0, inherit, 0, &wpid, &hproc))
            XSRETURN_UNDEF;

          /* do it like perl, dadadoop dadadoop */
          w32_child_handles [w32_num_children] = hproc;
          w32_child_pids    [w32_num_children] = wpid;
          ++w32_num_children;

          pid = wpid;
        }
#elif USE_SPAWN
        {
          pid_t xpid;
          int *held = 0, nheld = 0;

          if (!inherit)
            nheld = cloexec_hold (aTHX_ &held);

          errno = (ix ? posix_spawnp : posix_spawn) (&xpid, path, 0, 0, cargv, cenvp);

          if (held)
            cloexec_release (aTHX_ held, nheld);

          if (errno)
            XSRETURN_UNDEF;

          pid = xpid;
        }
#else
        {
          int *held = 0, nheld = 0;

          if (!inherit)
            nheld = cloexec_hold (aTHX_ &held);

          pid = (ix ? fork : vfork) ();

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

          /* parent only: the child is gone through exec, or never was */
          if (held)
            cloexec_release (aTHX_ held, nheld);

          if (pid < 0)
            XSRETURN_UNDEF;
        }
#endif

        RETVAL = pid;
}
	OUTPUT: RETVAL

void
spawn3 (int fd_in, int fd_out, int fd_err, const char *path, SV *argv, SV *envp = &PL_sv_undef, SV *opts = &PL_sv_undef)
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
        int inherit = spawn_options (aTHX_ &envp, opts);
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
          DWORD wpid;
          HANDLE hproc, hdup;
          HANDLE hstd [3];
          int redirects = 0;

          /* A descriptor that is already its own target means "inherit ours",
           * exactly as on POSIX. If all three are, nothing is being
           * redirected and this is spawn with a child object on the end: say
           * so, and the standard handles are left alone rather than being
           * handed back to the child explicitly, which is the one way the two
           * could still have differed. */
          for (i = 0; i < 3; ++i)
            if (rfd [i] >= 0 && rfd [i] != i)
              redirects = 1;

          if (redirects)
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

          if (!w32_spawn (aTHX_ path, ix, cargv, cenvp, SvOK (envp),
                          redirects ? hstd : 0, inherit, rfd, &wpid, &hproc))
            XSRETURN_UNDEF;

          /* Same bookkeeping spawn does, so waitpid and $? work on the pid. */
          w32_child_handles [w32_num_children] = hproc;
          w32_child_pids    [w32_num_children] = wpid;
          ++w32_num_children;

          /* The caller gets its own reference: perl closes the one above when
           * the child is reaped, and a handle being waited on must not vanish
           * underneath the waiter. Not inheritable, or it would leak into every
           * subsequent child spawned with handle inheritance on. */
          if (!DuplicateHandle (GetCurrentProcess (), hproc,
                                GetCurrentProcess (), &hdup,
                                0, FALSE, DUPLICATE_SAME_ACCESS))
            hdup = 0;

          hchild = hdup;
          pid    = wpid;
        }
#elif USE_SPAWN
        {
          pid_t xpid;
          posix_spawn_file_actions_t fa;
          int *held = 0, nheld = 0;

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

          if (!inherit)
            nheld = cloexec_hold (aTHX_ &held);

          errno = (ix ? posix_spawnp : posix_spawn) (&xpid, path, &fa, 0, cargv, cenvp);

          posix_spawn_file_actions_destroy (&fa);

          if (held)
            cloexec_release (aTHX_ held, nheld);

          if (errno)
            XSRETURN_UNDEF;

          pid = xpid;
        }
#else
        {
          int *held = 0, nheld = 0;

          if (!inherit)
            nheld = cloexec_hold (aTHX_ &held);

          pid = (ix ? fork : vfork) ();

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

          /* parent only: the child is gone through exec, or never was */
          if (held)
            cloexec_release (aTHX_ held, nheld);

          if (pid < 0)
            XSRETURN_UNDEF;
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

void
setOptions (...)
	PPCODE:
{
        int want [OPT_COUNT];
        int i, k;

        if (items & 1)
          croak ("Proc::FastSpawn::setOptions: expected a list of key => value pairs");

        Copy (spawn_opt_on, want, OPT_COUNT, int);

        for (i = 0; i < items; i += 2)
          {
            STRLEN len;
            const char *key = SvPV (ST (i), len);

            for (k = 0; k < OPT_COUNT; ++k)
              if (len == spawn_opt [k].len && memEQ (key, spawn_opt [k].name, len))
                break;

            if (k == OPT_COUNT)
              croak ("Proc::FastSpawn::setOptions: unknown option %.*s", (int)len, key);

            want [k] = SvTRUE (ST (i + 1)) ? 1 : 0;
          }

        /* Reject what CreateProcess would, and do it before anything takes
         * effect, so a call that does not make sense leaves the settings as
         * they were rather than half-applying. */
        if (want [OPT_NEW_CONSOLE] && want [OPT_DETACHED])
          croak ("Proc::FastSpawn::setOptions: create_new_console and detached_process are mutually exclusive");

        if (want [OPT_NO_WINDOW] && (want [OPT_NEW_CONSOLE] || want [OPT_DETACHED]))
          croak ("Proc::FastSpawn::setOptions: create_no_window does nothing next to create_new_console or detached_process");

        /* Hand back what was in force, so a caller can put it back. Reading
         * the arguments is done with, PPCODE pushes over them. */
        EXTEND (SP, OPT_COUNT * 2);

        for (k = 0; k < OPT_COUNT; ++k)
          {
            PUSHs (sv_2mortal (newSVpvn (spawn_opt [k].name, spawn_opt [k].len)));
            PUSHs (sv_2mortal (newSViv (spawn_opt_on [k])));
          }

        Copy (want, spawn_opt_on, OPT_COUNT, int);
}

