/*
 * Test of core patch 0009 (ow_sta_channel_override_action.h): which channel the STA
 * channel override gives an AP. Builds against a patched core tree:
 *
 *   cc -Wall -Werror -I<core>/src/lib/ow/src ow_sta_channel_override_action_test.c && ./a.out
 *
 * (scripts/test-core.sh does that against the assembled sources.) The sequence part models
 * a pod's AP on a radio whose backhaul station sits on another channel, with 0008's
 * restart for a CSA hostapd refuses: the AP must end on the station's channel without a
 * restart loop.
 */
#include <stdio.h>
#include "ow_sta_channel_override_action.h"

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

#define DONT OW_STA_CHANNEL_OVERRIDE_DONT_CHANGE
#define AP   OW_STA_CHANNEL_OVERRIDE_USE_AP_STATE_CHAN
#define STA  OW_STA_CHANNEL_OVERRIDE_USE_STA_STATE_CHAN

/* The channel an AP is configured for, given the action. */
static int conf_channel(enum ow_sta_channel_override_action a, int configured, int ap_state, int sta)
{
    switch (a) {
        case DONT: return configured;
        case AP: return ap_state;
        case STA: return sta;
    }
    return -1;
}

int main(void)
{
    printf("1. the decision\n");
    CHECK(ow_sta_channel_override_action_for(false, true, false) == DONT, "no station: the AP keeps its configuration");
    CHECK(ow_sta_channel_override_action_for(false, false, false) == DONT, "no station, AP not running: likewise");
    CHECK(ow_sta_channel_override_action_for(true, true, false) == STA, "station linked, AP running: the station's channel");
    CHECK(ow_sta_channel_override_action_for(true, true, true) == AP, "station linked, AP channel just changed: its own channel while settling");
    CHECK(ow_sta_channel_override_action_for(true, false, false) == STA,
          "station linked, AP not running: it starts on the station's channel (was: its configured one)");
    CHECK(ow_sta_channel_override_action_for(true, false, true) == STA,
          "station linked, AP not running while settling: the station's channel too");

    printf("2. a pod's AP after the root AP moved (configured 6, station on 2, CSA refused)\n");
    {
        const int configured = 6, sta = 2;
        int ap_channel = 0;   /* not running */
        int restarts = 0, i;
        bool ap_running = false;

        for (i = 0; i < 10; i++) {
            const enum ow_sta_channel_override_action a =
                ow_sta_channel_override_action_for(true, ap_running, false);
            const int want = conf_channel(a, configured, ap_channel, sta);
            if (!ap_running) {
                ap_channel = want;          /* started on the configured channel */
                ap_running = true;
            } else if (want != ap_channel) {
                ap_running = false;         /* 0008: CSA refused -> restart */
                restarts++;
            }
        }
        CHECK(ap_channel == sta && restarts == 0,
              "the AP starts on the station's channel and stays: channel %d, %d restarts", ap_channel, restarts);
    }

    printf("== %s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
