/* Force-included into every HWSIM_POD compile unit (see HWSIM_POD.mk).
 * The cfg80211 platform is written against musl (OpenWrt), which has
 * strlcpy(); glibc 2.31 (Ubuntu 20.04, the pod's base) does not. A real
 * function, not a macro: OpenSync's os.h defines its own strlcpy() macro,
 * which then takes precedence wherever os.h is included. */
#ifndef HWSIM_POD_COMPAT_H
#define HWSIM_POD_COMPAT_H

/* glibc hides dladdr()/Dl_info and friends behind _GNU_SOURCE (musl does
 * not). Defined empty -- like the sources that define it themselves -- and
 * only if a unit's own -D_GNU_SOURCE did not already. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <string.h>

#if !defined(__cplusplus) && !defined(strlcpy)
static inline size_t strlcpy(char *dst, const char *src, size_t size)
{
    size_t len = strlen(src);
    if (size) {
        size_t n = len >= size ? size - 1 : len;
        memcpy(dst, src, n);
        dst[n] = '\0';
    }
    return len;
}
#endif

#endif
