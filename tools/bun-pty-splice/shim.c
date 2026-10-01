/*
 * shim.so — bionic compat shim for musl-built librust_pty (bun-pty 0.4.11).
 *
 * bionic (Android 9) lacks: bcmp, __errno_location, __xpg_strerror_r,
 * posix_spawn_file_actions_addchdir_np. We provide those, plus our own
 * posix_spawn family so the musl .so's spawn path goes through our
 * fork+exec implementation (bionic A9 has no chdir spawn action).
 *
 * musl .so is binary-patched: DT_NEEDED "libc.so" -> "shim.so" (same length).
 * Flag constants interpreted with MUSL values (the .so was compiled with
 * musl headers): RESETIDS=1 SETPGROUP=2 SETSIGDEF=4 SETSIGMASK=8,
 * SETSID = 0x40 or 0x80 (both accepted).
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* ---------- trivial symbol shims ---------- */

int bcmp(const void *a, const void *b, size_t n) { return memcmp(a, b, n); }

int *__errno_location(void) { return __errno(); }

char *__xpg_strerror_r(int err, char *buf, size_t len) {
    /* bionic strerror_r is XSI (returns int); __xpg_ version returns char* */
    strerror_r(err, buf, len);
    return buf;
}

/* ---------- posix_spawn shadow implementation ---------- */

enum { ACT_DUP2 = 0, ACT_CHDIR = 1, ACT_CLOSE = 2, ACT_OPEN = 3 };

struct act_node {
    int type;
    int fd1, fd2;      /* dup2: fd1->fd2; close: fd1; open: fd2 = fd      */
    int oflag;
    char path[256];    /* chdir: dir; open: file                          */
    struct act_node *next;
};

struct act_rec {
    const void *key;
    struct act_node *head, *tail;
    struct act_rec *next;
};

struct attr_rec {
    const void *key;
    short flags;
    pid_t pgroup;
    sigset_t sigdef;
    sigset_t sigmask;
    struct attr_rec *next;
};

static struct act_rec *g_acts = NULL;
static struct attr_rec *g_attrs = NULL;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static struct act_rec *act_find(const void *key) {
    for (struct act_rec *r = g_acts; r; r = r->next)
        if (r->key == key) return r;
    return NULL;
}

static struct attr_rec *attr_find(const void *key) {
    for (struct attr_rec *r = g_attrs; r; r = r->next)
        if (r->key == key) return r;
    return NULL;
}

static struct act_node *act_new(void) {
    struct act_node *n = calloc(1, sizeof(*n));
    if (!n) abort();
    return n;
}

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *fa) {
    pthread_mutex_lock(&g_mu);
    struct act_rec *r = act_find(fa);
    if (r) { pthread_mutex_unlock(&g_mu); return 0; } /* idempotent-ish */
    r = calloc(1, sizeof(*r));
    if (!r) { pthread_mutex_unlock(&g_mu); return ENOMEM; }
    r->key = fa;
    r->next = g_acts;
    g_acts = r;
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *fa) {
    pthread_mutex_lock(&g_mu);
    struct act_rec **pp = &g_acts;
    while (*pp && (*pp)->key != fa) pp = &(*pp)->next;
    if (*pp) {
        struct act_rec *r = *pp;
        *pp = r->next;
        struct act_node *n = r->head;
        while (n) { struct act_node *nx = n->next; free(n); n = nx; }
        free(r);
    }
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *fa, int fd1, int fd2) {
    pthread_mutex_lock(&g_mu);
    struct act_rec *r = act_find(fa);
    int rc = 0;
    if (r) {
        struct act_node *n = act_new();
        n->type = ACT_DUP2; n->fd1 = fd1; n->fd2 = fd2;
        if (r->tail) r->tail = r->tail->next = n; else r->head = r->tail = n;
    } else rc = ENOENT;
    pthread_mutex_unlock(&g_mu);
    return rc;
}

int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *fa, const char *path) {
    pthread_mutex_lock(&g_mu);
    struct act_rec *r = act_find(fa);
    int rc = 0;
    if (r) {
        struct act_node *n = act_new();
        n->type = ACT_CHDIR;
        snprintf(n->path, sizeof(n->path), "%s", path ? path : "");
        if (r->tail) r->tail = r->tail->next = n; else r->head = r->tail = n;
    } else rc = ENOENT;
    pthread_mutex_unlock(&g_mu);
    return rc;
}

int posix_spawnattr_init(posix_spawnattr_t *attr) {
    pthread_mutex_lock(&g_mu);
    struct attr_rec *r = attr_find(attr);
    if (!r) {
        r = calloc(1, sizeof(*r));
        if (!r) { pthread_mutex_unlock(&g_mu); return ENOMEM; }
        r->key = attr;
        r->next = g_attrs;
        g_attrs = r;
    }
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int posix_spawnattr_destroy(posix_spawnattr_t *attr) {
    pthread_mutex_lock(&g_mu);
    struct attr_rec **pp = &g_attrs;
    while (*pp && (*pp)->key != attr) pp = &(*pp)->next;
    if (*pp) { struct attr_rec *r = *pp; *pp = r->next; free(r); }
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags) {
    pthread_mutex_lock(&g_mu);
    struct attr_rec *r = attr_find(attr);
    if (r) r->flags = flags; else { pthread_mutex_unlock(&g_mu); return ENOENT; }
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int posix_spawnattr_setpgroup(posix_spawnattr_t *attr, pid_t pgroup) {
    pthread_mutex_lock(&g_mu);
    struct attr_rec *r = attr_find(attr);
    if (r) r->pgroup = pgroup; else { pthread_mutex_unlock(&g_mu); return ENOENT; }
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int posix_spawnattr_setsigdefault(posix_spawnattr_t *attr, const sigset_t *set) {
    pthread_mutex_lock(&g_mu);
    struct attr_rec *r = attr_find(attr);
    if (r) memcpy(&r->sigdef, set, sizeof(sigset_t));
    else { pthread_mutex_unlock(&g_mu); return ENOENT; }
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int posix_spawnattr_setsigmask(posix_spawnattr_t *attr, const sigset_t *set) {
    pthread_mutex_lock(&g_mu);
    struct attr_rec *r = attr_find(attr);
    if (r) memcpy(&r->sigmask, set, sizeof(sigset_t));
    else { pthread_mutex_unlock(&g_mu); return ENOENT; }
    pthread_mutex_unlock(&g_mu);
    return 0;
}

/* PATH search + exec, malloc-free in child. Returns only on failure. */
static void child_exec(const char *file, char *const argv[], char *const envp[]) {
    char pathbuf[1024];
    if (strchr(file, '/')) {
        execve(file, argv, envp);
        _exit(127);
    }
    /* PATH from envp, fallback to environ */
    const char *path = NULL;
    for (char *const *e = envp; *e; e++)
        if (strncmp(*e, "PATH=", 5) == 0) { path = *e + 5; break; }
    if (!path) path = getenv("PATH");
    if (!path) path = "/system/bin:/system/xbin";
    const char *p = path;
    while (1) {
        const char *colon = strchr(p, ':');
        size_t dlen = colon ? (size_t)(colon - p) : strlen(p);
        if (dlen == 0) { p = "."; dlen = 1; }
        if (dlen < sizeof(pathbuf) - 2 - strlen(file)) {
            memcpy(pathbuf, p, dlen);
            pathbuf[dlen] = '/';
            strcpy(pathbuf + dlen + 1, file);
            execve(pathbuf, argv, envp);
        }
        if (!colon) break;
        p = colon + 1;
    }
    _exit(127);
}

static int do_spawn(pid_t *pid, const char *file,
                    const posix_spawn_file_actions_t *fa,
                    const posix_spawnattr_t *attr,
                    char *const argv[], char *const envp[]) {
    /* snapshot under lock, then fork */
    struct {
        short flags; pid_t pgroup; sigset_t sigdef, sigmask;
        int has_attr;
    } A;
    memset(&A, 0, sizeof(A));
    struct act_node snapshot[32];
    int nacts = 0;
    pthread_mutex_lock(&g_mu);
    if (attr) {
        struct attr_rec *r = attr_find(attr);
        if (r) { A.flags = r->flags; A.pgroup = r->pgroup;
                 A.sigdef = r->sigdef; A.sigmask = r->sigmask; A.has_attr = 1; }
    }
    if (fa) {
        struct act_rec *r = act_find(fa);
        if (r) for (struct act_node *n = r->head; n && nacts < 32; n = n->next)
            snapshot[nacts++] = *n;
    }
    pthread_mutex_unlock(&g_mu);

    pid_t p = fork();
    if (p < 0) return errno;
    if (p == 0) {
        /* child */
        if (A.has_attr) {
            if (A.flags & (0x40 | 0x80)) setsid();     /* SETSID (musl 0x80 / glibc 0x40) */
            if (A.flags & 0x02) setpgid(0, A.pgroup);  /* SETPGROUP */
            if (A.flags & 0x04) {                      /* SETSIGDEF */
                for (int s = 1; s < 64; s++)
                    if (sigismember(&A.sigdef, s) == 1) signal(s, SIG_DFL);
            }
            if (A.flags & 0x08)                        /* SETSIGMASK */
                sigprocmask(SIG_SETMASK, &A.sigmask, NULL);
        }
        for (int i = 0; i < nacts; i++) {
            struct act_node *n = &snapshot[i];
            switch (n->type) {
            case ACT_DUP2:  dup2(n->fd1, n->fd2); break;
            case ACT_CHDIR: chdir(n->path); break;
            case ACT_CLOSE: close(n->fd1); break;
            case ACT_OPEN:  { int fd = open(n->path, n->oflag, 0600);
                              if (fd >= 0) { dup2(fd, n->fd2); if (fd != n->fd2) close(fd); } }
                              break;
            }
        }
        child_exec(file, argv, envp);
        _exit(127);
    }
    *pid = p;
    return 0;
}

int posix_spawnp(pid_t *pid, const char *file,
                 const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr,
                 char *const argv[], char *const envp[]) {
    return do_spawn(pid, file, fa, attr, argv, envp);
}

int posix_spawn(pid_t *pid, const char *path,
                const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr,
                char *const argv[], char *const envp[]) {
    return do_spawn(pid, path, fa, attr, argv, envp);
}

/* canary: log when shim (and thus patched pty lib) is dlopened.
 * Opt-in only: set OPENCODE_PTY_SHIM_LOG=<path> to enable (debug aid);
 * shipped builds stay side-effect free when the var is unset. */
#include <stdio.h>
__attribute__((constructor)) static void shim_ctor(void) {
    const char *log = getenv("OPENCODE_PTY_SHIM_LOG");
    if (!log || !*log) return;
    FILE *f = fopen(log, "a");
    if (f) { fprintf(f, "shim loaded, pid=%d\n", getpid()); fclose(f); }
}
