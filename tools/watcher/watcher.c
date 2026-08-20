/*
 * watcher.c -- recursive inotify directory watcher daemon
 *
 * Pure C, libc + inotify only (zero third-party dependencies).
 *
 * Watches <root> recursively, following symlinks with a depth guard
 * (--max-depth, default 32) and a visited-inode set that breaks cycles.
 * Events are debounced (--debounce-ms, default 50) and coalesced by
 * (type, path), then emitted as JSON Lines over stdout:
 *
 *   {"t":"create|modify|delete|rename","p":"<path relative to root>"}
 *
 * rename events carry the destination path (most useful for reload
 * semantics: editors rename temp -> target).
 *
 * CLI:
 *   watcher <root> [--debounce-ms N] [--max-depth D]
 *   watcher --help
 *   watcher --version
 *
 * Build (NDK static preferred):
 *   cc -O2 -static -o watcher watcher.c
 *   cc -O2 -static-pie -o watcher watcher.c   # if static pie required
 *   cc -O2 -o watcher watcher.c               # dynamic fallback
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <sys/types.h>

#define DEFAULT_DEBOUNCE_MS 50
#define DEFAULT_MAX_DEPTH   32
#define WATCHER_VERSION     "0.1.0"
#define EVENT_BUF_SIZE      (64 * 1024)

/* Everything we care about, incl. close_write for editor-save semantics. */
#define WATCH_MASK (IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | \
                    IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF)

static int infd = -1;
static char *root_path;              /* normalized root (no trailing slash) */
static size_t root_len;
static int debounce_ms = DEFAULT_DEBOUNCE_MS;
static int max_depth = DEFAULT_MAX_DEPTH;
static volatile sig_atomic_t g_stop = 0;

/* ---------------- growable string ---------------- */

typedef struct { char *data; size_t len, cap; } strbuf;

static void sb_grow(strbuf *sb, size_t need) {
    if (sb->cap >= need) return;
    size_t nc = sb->cap ? sb->cap : 256;
    while (nc < need) nc *= 2;
    char *nd = realloc(sb->data, nc);
    if (!nd) { fprintf(stderr, "watcher: out of memory\n"); exit(1); }
    sb->data = nd;
    sb->cap = nc;
}

static void sb_append(strbuf *sb, const char *s, size_t n) {
    sb_grow(sb, sb->len + n + 1);
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

static void sb_pushc(strbuf *sb, char c) { sb_append(sb, &c, 1); }

static void sb_restore(strbuf *sb, size_t len) {
    sb->len = len;
    sb->data[len] = '\0';
}

/* ---------------- watch table (wd -> path/depth) ---------------- */

typedef struct { int wd; char *path; int depth; } watch_entry;
static watch_entry *watches = NULL;
static size_t watch_n = 0, watch_cap = 0;

static void watch_record(int wd, const char *path, int depth) {
    if (wd < 0) return;
    if (watch_n == watch_cap) {
        watch_cap = watch_cap ? watch_cap * 2 : 1024;
        watch_entry *nw = realloc(watches, watch_cap * sizeof *nw);
        if (!nw) { fprintf(stderr, "watcher: out of memory\n"); exit(1); }
        watches = nw;
    }
    watches[watch_n].wd = wd;
    watches[watch_n].path = strdup(path);
    watches[watch_n].depth = depth;
    watch_n++;
}

static const char *watch_path(int wd) {
    for (size_t i = 0; i < watch_n; i++)
        if (watches[i].wd == wd) return watches[i].path;
    return NULL;
}

static int watch_depth(int wd) {
    for (size_t i = 0; i < watch_n; i++)
        if (watches[i].wd == wd) return watches[i].depth;
    return -1;
}

static void watch_remove(int wd) {
    for (size_t i = 0; i < watch_n; i++) {
        if (watches[i].wd == wd) {
            free(watches[i].path);
            watches[i] = watches[watch_n - 1];
            watch_n--;
            return;
        }
    }
}

/* ---------------- visited inode set (symlink cycle guard) ---------------- */

typedef struct { dev_t dev; ino_t ino; } node_key;
static node_key *visited = NULL;
static size_t visited_n = 0, visited_cap = 0;

static int visited_check(dev_t dev, ino_t ino) {
    for (size_t i = 0; i < visited_n; i++)
        if (visited[i].dev == dev && visited[i].ino == ino) return 1;
    return 0;
}

static void visited_add(dev_t dev, ino_t ino) {
    if (visited_n == visited_cap) {
        visited_cap = visited_cap ? visited_cap * 2 : 256;
        node_key *nv = realloc(visited, visited_cap * sizeof *nv);
        if (!nv) { fprintf(stderr, "watcher: out of memory\n"); exit(1); }
        visited = nv;
    }
    visited[visited_n].dev = dev;
    visited[visited_n].ino = ino;
    visited_n++;
}

/* ---------------- pending (debounced) events ---------------- */

enum { EV_CREATE, EV_MODIFY, EV_DELETE, EV_RENAME };
static const char *EV_NAME[] = { "create", "modify", "delete", "rename" };

typedef struct { int type; char *path; } pend_ev;
static pend_ev *pend = NULL;
static size_t pend_n = 0, pend_cap = 0;

/* Coalesce: same (type, path) collapses into one pending event. */
static void pend_add(int type, const char *path) {
    for (size_t i = 0; i < pend_n; i++)
        if (pend[i].type == type && strcmp(pend[i].path, path) == 0) return;
    if (pend_n == pend_cap) {
        pend_cap = pend_cap ? pend_cap * 2 : 64;
        pend_ev *np = realloc(pend, pend_cap * sizeof *np);
        if (!np) { fprintf(stderr, "watcher: out of memory\n"); exit(1); }
        pend = np;
    }
    pend[pend_n].type = type;
    pend[pend_n].path = strdup(path);
    pend_n++;
}

/* ---------------- rename cookie bridge (moved_from -> moved_to) ---------------- */

typedef struct { uint32_t cookie; char *path; } cookie_ev;
static cookie_ev *cookies = NULL;
static size_t cookie_n = 0, cookie_cap = 0;

static void cookie_store(uint32_t cookie, const char *path) {
    for (size_t i = 0; i < cookie_n; i++)
        if (cookies[i].cookie == cookie) {
            free(cookies[i].path);
            cookies[i].path = strdup(path);
            return;
        }
    if (cookie_n == cookie_cap) {
        cookie_cap = cookie_cap ? cookie_cap * 2 : 16;
        cookie_ev *nc = realloc(cookies, cookie_cap * sizeof *nc);
        if (!nc) { fprintf(stderr, "watcher: out of memory\n"); exit(1); }
        cookies = nc;
    }
    cookies[cookie_n].cookie = cookie;
    cookies[cookie_n].path = strdup(path);
    cookie_n++;
}

/* Returns heap-owned path, caller frees. NULL if not found. */
static char *cookie_take(uint32_t cookie) {
    for (size_t i = 0; i < cookie_n; i++) {
        if (cookies[i].cookie == cookie) {
            char *p = cookies[i].path;
            cookies[i] = cookies[cookie_n - 1];
            cookie_n--;
            return p;
        }
    }
    return NULL;
}

/* ---------------- recursive walk + watch install ---------------- */

static void walk_add(strbuf *path, int depth, int emit) {
    if (depth > max_depth) return;
    struct stat st;
    if (stat(path->data, &st) != 0) return;          /* follows symlinks */
    if (!S_ISDIR(st.st_mode)) return;
    if (visited_check(st.st_dev, st.st_ino)) return; /* cycle guard */
    visited_add(st.st_dev, st.st_ino);

    int wd = inotify_add_watch(infd, path->data, WATCH_MASK);
    watch_record(wd, path->data, depth);

    DIR *d = opendir(path->data);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        size_t save = path->len;
        sb_pushc(path, '/');
        sb_append(path, e->d_name, strlen(e->d_name));
        if (emit) pend_add(EV_CREATE, path->data);
        struct stat cst;
        if (stat(path->data, &cst) == 0 && S_ISDIR(cst.st_mode))
            walk_add(path, depth + 1, emit);
        sb_restore(path, save);
    }
    closedir(d);
}

/* ---------------- JSON emission ---------------- */

static void emit_json(const char *type, const char *rel) {
    fputs("{\"t\":\"", stdout);
    fputs(type, stdout);
    fputs("\",\"p\":\"", stdout);
    for (const unsigned char *c = (const unsigned char *)rel; *c; c++) {
        switch (*c) {
        case '"':  fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*c < 0x20) printf("\\u%04x", *c);
            else putchar(*c);
        }
    }
    fputs("\"}\n", stdout);
}

static const char *rel_of(const char *full) {
    if (strncmp(full, root_path, root_len) == 0 && full[root_len] == '/')
        return full + root_len + 1;
    return full; /* safety fallback: emit as-is */
}

/* ---------------- event pipeline ---------------- */

static void handle_event(const struct inotify_event *ev) {
    if (ev->mask & (IN_IGNORED | IN_DELETE_SELF)) {
        watch_remove(ev->wd);
        return;
    }
    if (ev->len == 0) return; /* no name attached */

    const char *base = watch_path(ev->wd);
    if (!base) return;
    int depth = watch_depth(ev->wd);
    if (depth < 0) depth = 0;

    strbuf full = {0};
    sb_append(&full, base, strlen(base));
    sb_pushc(&full, '/');
    sb_append(&full, ev->name, strlen(ev->name));

    struct stat st;
    int is_dir = (stat(full.data, &st) == 0 && S_ISDIR(st.st_mode));

    if (ev->mask & IN_MOVED_TO) {
        char *from = cookie_take(ev->cookie);
        if (from) {
            pend_add(EV_RENAME, full.data); /* destination path */
            free(from);
            if (is_dir) walk_add(&full, depth + 1, 1);
        } else {
            pend_add(EV_CREATE, full.data);
            if (is_dir) walk_add(&full, depth + 1, 1);
        }
    } else if (ev->mask & IN_MOVED_FROM) {
        cookie_store(ev->cookie, full.data); /* wait for its moved_to */
    } else if (ev->mask & IN_CREATE) {
        pend_add(EV_CREATE, full.data);
        if (is_dir) walk_add(&full, depth + 1, 1);
    } else if (ev->mask & (IN_MODIFY | IN_CLOSE_WRITE)) {
        pend_add(EV_MODIFY, full.data);
    } else if (ev->mask & IN_DELETE) {
        pend_add(EV_DELETE, full.data);
    }
    free(full.data);
}

static void drain_events(void) {
    char buf[EVENT_BUF_SIZE];
    for (;;) {
        ssize_t n = read(infd, buf, sizeof buf);
        if (n <= 0) break; /* EAGAIN or error */
        const char *p = buf;
        while (p < buf + n) {
            const struct inotify_event *ev = (const struct inotify_event *)p;
            handle_event(ev);
            p += sizeof(struct inotify_event) + ev->len;
        }
    }
}

static void flush_pending(void) {
    /* unmatched moved_from events (rename target outside tree) -> delete */
    for (size_t i = 0; i < cookie_n; i++) {
        pend_add(EV_DELETE, cookies[i].path);
        free(cookies[i].path);
    }
    cookie_n = 0;

    for (size_t i = 0; i < pend_n; i++) {
        emit_json(EV_NAME[pend[i].type], rel_of(pend[i].path));
        free(pend[i].path);
    }
    pend_n = 0;
}

/* ---------------- CLI ---------------- */

static void usage(FILE *out) {
    fprintf(out,
        "usage: watcher <root> [--debounce-ms N] [--max-depth D]\n"
        "       watcher --help\n"
        "\n"
        "Recursive inotify directory watcher. Emits JSON Lines events on\n"
        "stdout: {\"t\":\"create|modify|delete|rename\",\"p\":\"<rel path>\"}\n"
        "\n"
        "  root             directory to watch (required)\n"
        "  --debounce-ms N  debounce window in ms (default %d)\n"
        "  --max-depth D    max recursion depth, follows symlinks (default %d)\n"
        "  --help           show this help and exit\n"
        "  --version        show version and exit\n",
        DEFAULT_DEBOUNCE_MS, DEFAULT_MAX_DEPTH);
}

static void on_signal(int sig) { (void)sig; g_stop = 1; }

int main(int argc, char **argv) {
    const char *root = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(stdout);
            return 0;
        } else if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-V") == 0) {
            printf("watcher %s\n", WATCHER_VERSION);
            return 0;
        } else if (strcmp(argv[i], "--debounce-ms") == 0 && i + 1 < argc) {
            debounce_ms = atoi(argv[++i]);
            if (debounce_ms < 0) debounce_ms = 0;
        } else if (strcmp(argv[i], "--max-depth") == 0 && i + 1 < argc) {
            max_depth = atoi(argv[++i]);
            if (max_depth < 0) max_depth = 0;
        } else if (!root) {
            root = argv[i];
        } else {
            fprintf(stderr, "watcher: unexpected argument: %s\n", argv[i]);
            usage(stderr);
            return 2;
        }
    }

    if (!root) {
        usage(stderr);
        return 2;
    }

    struct stat rst;
    if (stat(root, &rst) != 0 || !S_ISDIR(rst.st_mode)) {
        fprintf(stderr, "watcher: %s: %s\n", root,
                errno ? strerror(errno) : "not a directory");
        return 1;
    }

    root_len = strlen(root);
    while (root_len > 1 && root[root_len - 1] == '/') root_len--;
    root_path = strndup(root, root_len);
    if (!root_path) { fprintf(stderr, "watcher: out of memory\n"); return 1; }

    infd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (infd < 0) { perror("watcher: inotify_init1"); return 1; }

    setvbuf(stdout, NULL, _IONBF, 0); /* events must arrive immediately */
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* initial enumeration: full recursive scan + watch install */
    strbuf rootb = {0};
    sb_append(&rootb, root_path, root_len);
    walk_add(&rootb, 0, 0);
    free(rootb.data);

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double scan_ms = (t1.tv_sec - t0.tv_sec) * 1000.0 +
                     (t1.tv_nsec - t0.tv_nsec) / 1e6;
    fprintf(stderr,
            "watcher: watching %s (%zu dirs, scan %.1f ms, debounce %d ms, max-depth %d)\n",
            root_path, watch_n, scan_ms, debounce_ms, max_depth);

    for (;;) {
        struct pollfd pfd = { .fd = infd, .events = POLLIN };
        int pr = poll(&pfd, 1, debounce_ms);
        if (g_stop) break;
        if (pr < 0) {
            if (errno == EINTR) continue;
            perror("watcher: poll");
            break;
        }
        if (pr == 0) {
            flush_pending(); /* debounce window elapsed -> emit batch */
            continue;
        }
        if (pfd.revents & POLLIN) drain_events();
    }

    flush_pending();
    close(infd);
    return 0;
}
