#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/// Starts `path` with `argv` and `envp` in `cwd`, as the session leader of a new pseudo-terminal of
/// `rows` x `cols`. Stores the terminal's master side in `*master_fd` and returns the child's pid,
/// or -1 with errno set. Everything between fork and exec happens in C, where it is async-signal-safe.
pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                 unsigned short rows, unsigned short cols, int *master_fd);

/// Tells the terminal (and so the program in it) its new size. Returns 0, or -1 with errno set.
int cpty_resize(int master_fd, unsigned short rows, unsigned short cols);

#endif
