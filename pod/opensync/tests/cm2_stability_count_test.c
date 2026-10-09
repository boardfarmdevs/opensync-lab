/*
 * Test of core patch 0007 (cm2_stability_count.h): a router-check failure counts once per
 * short stability interval per uplink. Builds against a patched core tree:
 *
 *   cc -Wall -Werror -I<core>/src/cm2/src cm2_stability_count_test.c && ./a.out
 *
 * (scripts/test-core.sh does that against the assembled sources.) The fatal rule is cm2's
 * own: cm2_stability_handle_fatal_state(stored counter) restarts OpenSync when the stored
 * counter + 1 > CONFIG_CM2_STABILITY_THRESH_FATAL, the stored counter being the one the
 * previous check wrote.
 */
#include <stdio.h>
#include <stdlib.h>
#include "cm2_stability_count.h"

#define INTERVAL     10 /* CONFIG_CM2_STABILITY_SHORT_INTERVAL */
#define THRESH_FATAL 8  /* CONFIG_CM2_STABILITY_THRESH_FATAL */

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

/* One check of if_name at t: the stored counter after it, and whether it was fatal. */
static bool check(struct cm2_stability_count *sc, const char *if_name, int *stored, bool failed,
                  time_t t, int interval, bool *counted)
{
    const bool fatal = failed && (*stored + 1 > THRESH_FATAL);
    *stored = cm2_stability_count_router(sc, if_name, *stored, failed, t, interval, counted);
    return fatal;
}

/* Seconds from the first failure to the fatal check, the router gone, a check every step s. */
static int seconds_to_fatal(int step, int interval)
{
    struct cm2_stability_count sc;
    int stored = -1;
    bool counted;
    time_t t;

    memset(&sc, 0, sizeof(sc));
    for (t = 1000; t < 1000 + 3600; t += step)
        if (check(&sc, "bhaul-sta-50", &stored, true, t, interval, &counted)) return (int)(t - 1000);
    return -1;
}

int main(void)
{
    struct cm2_stability_count sc;
    int stored, a, b, i, s;
    bool counted;

    printf("1. back-to-back failures inside one interval count once\n");
    memset(&sc, 0, sizeof(sc));
    stored = 0;
    check(&sc, "bhaul-sta-50", &stored, true, 100, INTERVAL, &counted);
    CHECK(stored == 1 && counted, "the first failure counts: %d", stored);
    for (i = 0; i < 4; i++) {
        check(&sc, "bhaul-sta-50", &stored, true, 102 + 2 * i, INTERVAL, &counted);
        CHECK(stored == 1 && !counted, "a failure %d s later is held at %d", 2 + 2 * i, stored);
    }
    check(&sc, "bhaul-sta-50", &stored, true, 110, INTERVAL, &counted);
    CHECK(stored == 2 && counted, "one interval later it counts: %d", stored);
    /* the lab's case: checks every 2 s for 15 s (07:41:22-07:41:37Z) */
    memset(&sc, 0, sizeof(sc));
    stored = 0;
    for (s = 0; s <= 15; s += 2) check(&sc, "bhaul-sta-50", &stored, true, 200 + s, INTERVAL, &counted);
    CHECK(stored == 2, "8 checks in 15 s count 2, not 8: %d", stored);

    printf("2. a router really gone still reaches the fatal threshold in about 80 s\n");
    s = seconds_to_fatal(2, INTERVAL);
    CHECK(s >= 70 && s <= 90, "checks every 2 s: fatal after %d s", s);
    s = seconds_to_fatal(INTERVAL, INTERVAL);
    CHECK(s >= 70 && s <= 90, "the periodic check alone (every %d s): fatal after %d s", INTERVAL, s);
    s = seconds_to_fatal(2, 0);
    CHECK(s < 20, "(without the limit, checks every 2 s went fatal after %d s)", s);

    printf("3. a success resets the count\n");
    memset(&sc, 0, sizeof(sc));
    stored = 0;
    for (i = 0; i < 5; i++) check(&sc, "bhaul-sta-50", &stored, true, 300 + INTERVAL * i, INTERVAL, &counted);
    CHECK(stored == 5, "five intervals of failures: %d", stored);
    CHECK(!check(&sc, "bhaul-sta-50", &stored, false, 341, INTERVAL, &counted) && stored == 0,
          "a success: %d", stored);
    check(&sc, "bhaul-sta-50", &stored, true, 342, INTERVAL, &counted);
    CHECK(stored == 1 && counted, "the next failure counts from 1 at once: %d", stored);

    printf("4. separate uplinks count separately\n");
    memset(&sc, 0, sizeof(sc));
    a = b = 0;
    for (s = 0; s <= 20; s += 2) {
        check(&sc, "bhaul-sta-50", &a, true, 400 + s, INTERVAL, &counted);
        check(&sc, "eth0", &b, true, 400 + s, INTERVAL, &counted);
    }
    CHECK(a == 3 && b == 3, "interleaved failures of two uplinks for 20 s: %d and %d", a, b);
    memset(&sc, 0, sizeof(sc));
    a = 0;
    check(&sc, "bhaul-sta-50", &a, true, 500, INTERVAL, &counted);
    for (i = 0; i < CM2_STABILITY_COUNT_UPLINKS + 2; i++) {
        char name[16];
        int x = 0;
        snprintf(name, sizeof(name), "up%d", i);
        check(&sc, name, &x, true, 501 + i, INTERVAL, &counted);
    }
    check(&sc, "bhaul-sta-50", &a, true, 512, INTERVAL, &counted);
    CHECK(a == 2, "more uplinks than slots: the oldest is reused, nothing breaks (%d)", a);

    printf("== %s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
