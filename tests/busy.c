/*
 * busy.c — CPU-eating test workload for vcpulimit integration tests.
 *
 * Builds a single busy-loop. Optional second argument is a target CPU%
 * expressed as a number between 0 and 100; when given, the loop inserts a
 * small sleep every N iterations so the workload, run *without* cpulimit,
 * sits around that percentage. This lets tests assert that the limiter
 * moves the *observed* CPU% below the requested limit.
 *
 * Usage:
 *   busy                  # 100% CPU
 *   busy 50               # ~50% CPU (uncapped baseline)
 *   busy -                # alias for "50"
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    long sleep_every = 0;     /* iterations between sleeps */
    useconds_t sleep_us = 0;  /* sleep duration each time */

    if (argc >= 2) {
        int pct = atoi(argv[1]);
        if (pct <= 0 || pct >= 100) {
            fprintf(stderr, "usage: %s [0<pct<100]\n", argv[0]);
            return 2;
        }
        /* rough: spend pct% of time busy, (100-pct)% sleeping. */
        sleep_every = 1000;
        sleep_us   = (useconds_t)((100 - pct) * 200); /* 0..20ms */
    }

    unsigned long long i = 0;
    while (1) {
        if (sleep_every && (i % sleep_every) == 0) {
            usleep(sleep_us);
        }
        i++;
    }
}
