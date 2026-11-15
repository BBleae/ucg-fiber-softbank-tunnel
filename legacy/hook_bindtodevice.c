#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>

/*
 * LD_PRELOAD shim for ubios-udapi-server on UCG-Fiber
 *
 * Intercepts setsockopt(SO_BINDTODEVICE). When the caller binds to
 * "ip6tnl1" (the non-functional DS-Lite WAN tunnel), silently replace
 * the device name with "tun4" (the working IPIP6 tunnel).
 *
 * All other setsockopt calls pass through unchanged.
 *
 * Build (on macOS with zig):
 *   zig cc -target aarch64-linux-gnu -shared -fPIC -o hook_bindtodevice.so hook_bindtodevice.c
 *
 * Deploy:
 *   scp hook_bindtodevice.so ucg:/data/
 *   # Create systemd override for udapi-server (see instructions)
 */

typedef int (*real_setsockopt_t)(int, int, int, const void *, socklen_t);

int setsockopt(int fd, int level, int optname, const void *optval, socklen_t optlen) {
    real_setsockopt_t real_setsockopt = (real_setsockopt_t)dlsym(RTLD_NEXT, "setsockopt");
    if (!real_setsockopt) {
        errno = ENOSYS;
        return -1;
    }

    if (level == SOL_SOCKET && optname == SO_BINDTODEVICE &&
        optval && optlen >= 7 &&
        memcmp(optval, "ip6tnl1", 7) == 0) {
        /* Replace ip6tnl1 -> tun4 */
        return real_setsockopt(fd, level, optname, "tun4", 5);
    }

    return real_setsockopt(fd, level, optname, optval, optlen);
}
