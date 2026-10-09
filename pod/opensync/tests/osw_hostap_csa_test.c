/*
 * Test of core patch 0008 (osw_hostap_csa.h): how an AP's channel change is applied.
 * Builds against a patched core tree:
 *
 *   cc -Wall -Werror -I<core>/src/lib/osw/src osw_hostap_csa_test.c && ./a.out
 *
 * (scripts/test-core.sh does that against the assembled sources.) A BSS is modelled as
 * osw_hostap.c keeps it: whether its phy has hostapd CSA (csa_by_hostap), and whether
 * hostapd refused the last CHAN_SWITCH (csa_failed: set from the reply, cleared when
 * the BSS is added again).
 */
#include <stdio.h>
#include "osw_hostap_csa.h"

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

struct bss {
    bool csa_by_hostap;
    bool csa_failed;
    int channel;
    int csas;     /* CHAN_SWITCH commands sent */
    int restarts; /* remove + add */
};

/*
 * One confsync attempt to move bss to channel, a CSA-eligible change; hostapd answers a
 * CHAN_SWITCH with reply. Returns whether the BSS is on the channel afterwards.
 */
static bool attempt(struct bss *b, int channel, const char *reply)
{
    const struct osw_hostap_csa_plan p = osw_hostap_csa_plan(b->channel != channel, true,
                                                             b->csa_by_hostap, b->csa_failed);
    if (p.csa) {
        b->csas++;
        if (osw_hostap_csa_refused(reply))
            b->csa_failed = true;
        else
            b->channel = channel;
    }
    if (p.restart) {
        b->restarts++;
        b->csa_failed = false; /* cleared on add */
        b->channel = channel;
    }
    return b->channel == channel;
}

int main(void)
{
    struct bss b;
    struct osw_hostap_csa_plan p;

    printf("1. a refused CHAN_SWITCH leads to a restart on the new channel\n");
    b = (struct bss){ .csa_by_hostap = true, .channel = 2437 };
    CHECK(!attempt(&b, 2457, "FAIL") && b.csas == 1 && b.csa_failed,
          "the first attempt tries CSA, hostapd refuses, the refusal is kept");
    CHECK(attempt(&b, 2457, "FAIL") && b.restarts == 1 && b.csas == 1,
          "the next attempt restarts the BSS on the new channel, no second CSA");
    CHECK(!b.csa_failed, "the refusal is cleared once the BSS is added again");
    CHECK(!attempt(&b, 2417, "FAIL") && b.csas == 2 && attempt(&b, 2417, "FAIL") && b.restarts == 2,
          "a later move tries CSA again first, then restarts (%d CSAs, %d restarts)",
          b.csas, b.restarts);

    printf("2. a phy with no CSA setting gets its change applied\n");
    b = (struct bss){ .csa_by_hostap = false, .channel = 2437 };
    CHECK(attempt(&b, 2457, NULL) && b.restarts == 1 && b.csas == 0,
          "restarted on the new channel at the first attempt, no CHAN_SWITCH");

    printf("3. a working CSA stays a CSA\n");
    b = (struct bss){ .csa_by_hostap = true, .channel = 2437 };
    CHECK(attempt(&b, 2457, "OK") && b.csas == 1 && b.restarts == 0 && !b.csa_failed,
          "switched by CSA, no restart");
    CHECK(attempt(&b, 2412, "OK") && b.csas == 2 && b.restarts == 0, "and again for the next move");

    printf("4. what does not change\n");
    p = osw_hostap_csa_plan(false, true, true, true);
    CHECK(!p.csa && !p.restart, "no channel change: neither CSA nor restart");
    p = osw_hostap_csa_plan(true, false, true, false);
    CHECK(!p.csa && p.restart, "a change confsync does not mark CSA-eligible (a mode change, CAC): restart, as before");
    CHECK(osw_hostap_csa_refused("FAIL\n") && osw_hostap_csa_refused("FAIL-BUSY") &&
          !osw_hostap_csa_refused("OK\n") && !osw_hostap_csa_refused(NULL) && !osw_hostap_csa_refused(""),
          "hostapd's FAIL replies are refusals; OK, none and empty are not");

    printf("== %s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
