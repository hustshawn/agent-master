#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                 unsigned short rows, unsigned short cols, int *master_fd) {
    struct winsize size = {0};
    size.ws_row = rows;
    size.ws_col = cols;
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) return -1;
    if (pid == 0) {
        // The server's other descriptors (listeners, other sessions' terminals) must not leak into the agent.
        struct rlimit limit;
        int top = (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < 65536) ? (int)limit.rlim_cur : 65536;
        for (int fd = 3; fd < top; fd++) close(fd);
        // The server ignores SIGPIPE; the agent should start with default signal handling.
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        if (cwd && chdir(cwd) != 0) _exit(126);
        execve(path, argv, envp);
        _exit(127);
    }
    int flags = fcntl(master, F_GETFD);
    if (flags >= 0) fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    *master_fd = master;
    return pid;
}

int cpty_resize(int master_fd, unsigned short rows, unsigned short cols) {
    struct winsize size = {0};
    size.ws_row = rows;
    size.ws_col = cols;
    return ioctl(master_fd, TIOCSWINSZ, &size);
}
