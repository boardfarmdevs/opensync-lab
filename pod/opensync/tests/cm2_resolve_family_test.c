/*
 * Test of core patch 0010 (cm2_resolve_family.h): cm2_resolve() asks c-ares for an
 * address literal in its own family only (the other family's query would go to DNS, and
 * TRY_RESOLVE waits for it), and for a name in every family the uplink has. Builds
 * against a patched core tree:
 *
 *   cc -Wall -Werror -I<core>/src/cm2/src cm2_resolve_family_test.c && ./a.out
 *
 * (scripts/test-core.sh does that against the assembled sources.)
 */
#include <stdio.h>
#include <string.h>
#include "cm2_resolve_family.h"

static int failures;

#define CHECK(cond, ...)                                    \
    do {                                                    \
        if (cond) {                                         \
            printf("  ok    ");                             \
        } else {                                            \
            printf("  FAIL  ");                             \
            failures++;                                     \
        }                                                   \
        printf(__VA_ARGS__);                                \
        printf("\n");                                       \
    } while (0)

/* The families asked for hostname on an uplink with up4/up6, as "4", "6", "46" or "-". */
static const char *asked(const char *hostname, bool up4, bool up6)
{
    bool ipv4 = up4;
    bool ipv6 = up6;

    cm2_resolve_families(hostname, &ipv4, &ipv6);
    if (ipv4 && ipv6) return "46";
    if (ipv4) return "4";
    if (ipv6) return "6";
    return "-";
}

static void expect(const char *hostname, bool up4, bool up6, const char *want)
{
    const char *got = asked(hostname, up4, up6);

    CHECK(strcmp(got, want) == 0, "%-22s uplink %s%s%s: asks %-2s (want %s)", hostname,
          up4 ? "4" : "", up6 ? "6" : "", up4 || up6 ? "" : "-", got, want);
}

int main(void)
{
    printf("an IPv4 literal: AF_INET only, never AF_INET6 (2026-10-18: 180 s TRY_RESOLVE)\n");
    expect("10.0.0.1", true, true, "4");
    expect("10.101.0.40", true, true, "4");
    expect("192.168.178.1", true, true, "4");
    expect("10.0.0.1", true, false, "4");
    expect("10.0.0.1", false, true, "-");

    printf("an IPv6 literal: AF_INET6 only\n");
    expect("fd00::1", true, true, "6");
    expect("2001:dead:bed0::4fc9", true, true, "6");
    expect("::ffff:10.0.0.1", true, true, "6");
    expect("fd00::1", true, false, "-");

    printf("a name: every family the uplink has, as before\n");
    expect("wildfire.plume.tech", true, true, "46");
    expect("wildfire.plume.tech", true, false, "4");
    expect("wildfire.plume.tech", false, true, "6");
    expect("wildfire.plume.tech", false, false, "-");

    printf("not a literal (inet_pton refuses it): as before\n");
    expect("10.0.0", true, true, "46");
    expect("10.0.0.1x", true, true, "46");
    expect("[10.0.0.1]", true, true, "46");
    expect("", true, true, "46");

    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
