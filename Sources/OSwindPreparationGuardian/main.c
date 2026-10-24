// Owns a preparation process group and watches the native parent's pipe.
// Parent death closes the pipe even after SIGKILL; no shell or history access.
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <stdio.h>
#include <stdatomic.h>
#include <time.h>
extern char **environ;
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Signal flags require lock-free atomics");
static _Atomic int stopping = 0;
static void stop_requested(int signal_number) { (void)signal_number; atomic_store_explicit(&stopping, 1, memory_order_relaxed); }
static int failure(const char *stage, int code) { dprintf(STDERR_FILENO,"OSwind preparation guardian: %s (%d)\n",stage,code); return 125; }
static void stop_group(pid_t group) { kill(-group, SIGKILL); _exit(125); }
static long number(const char *text) {
    char *end = NULL; errno = 0; long value = strtol(text, &end, 10);
    return errno || !end || *end ? -1 : value;
}
int main(int argc, char **argv) {
    if (argc < 5 || argv[3][0] != '-' || argv[3][1] != '-' || argv[3][2] || argv[4][0] != '/') return failure("arguments",0);
    long watch_value = number(argv[1]), parent_value = number(argv[2]);
    pid_t group = getpid();
    if (watch_value < 3 || watch_value > 1024 || parent_value <= 0 || getpgrp() != group) return failure("group identity",0);
    int watch = (int)watch_value; pid_t parent_group = (pid_t)parent_value;
    if (fcntl(watch, F_GETFD) < 0 || fcntl(watch, F_SETFD, FD_CLOEXEC) < 0 || fcntl(watch, F_SETFL, fcntl(watch, F_GETFL) | O_NONBLOCK) < 0) return failure("watch descriptor",errno);
    struct sigaction action = {0}; action.sa_handler = stop_requested; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
    posix_spawn_file_actions_t files; posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&files) || posix_spawnattr_init(&attributes)) return failure("spawn actions",errno);
    for (int fd = 0; fd < 3; fd++) if (posix_spawn_file_actions_addinherit_np(&files, fd)) return failure("stdio inheritance",errno);
    sigset_t mask, defaults; sigemptyset(&mask); sigemptyset(&defaults);
    const int signals[] = {SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT};
    for (unsigned i = 0; i < sizeof(signals)/sizeof(signals[0]); i++) sigaddset(&defaults, signals[i]);
    if (posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) || posix_spawnattr_setsigmask(&attributes, &mask) || posix_spawnattr_setsigdefault(&attributes, &defaults)) return failure("child signal attributes",errno);
    pid_t child = 0; int started = posix_spawn(&child, argv[4], &files, &attributes, argv + 4, environ);
    posix_spawn_file_actions_destroy(&files); posix_spawnattr_destroy(&attributes);
    if (started || child <= 0) return failure("child spawn",started);
    for (;;) {
        char byte; ssize_t n = read(watch, &byte, 1);
        if (atomic_load_explicit(&stopping, memory_order_relaxed) || n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) stop_group(group);
        siginfo_t info = {0};
        if (waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT)) stop_group(group);
        if (info.si_pid == child) {
            // The guardian PID remains alive, reserving the old group number.
            // Join the live parent's group so cleanup can kill descendants
            // without killing the guardian before it returns the real status.
            if (setpgid(0, parent_group)) stop_group(group);
            kill(-group, SIGKILL);
            int status = 0; pid_t result;
            do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
            if (result != child) return 125;
            return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        }
        struct timespec delay = {0, 20000000}; nanosleep(&delay, NULL);
    }
}
