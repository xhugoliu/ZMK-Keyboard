#include <assert.h>
#include <stdio.h>
#include "replay_filter.h"

int main(void) {
    struct pi_history h = {0};
    assert(!pi_is_replay(&h, 24, true, 100));
    assert(!pi_is_replay(&h, 26, true, 120));
    assert(!pi_is_replay(&h, 24, false, 130));
    assert(!pi_is_replay(&h, 24, true, 150));
    /* Re-raising an old DOWN after UP and a newer DOWN must not count again. */
    assert(pi_is_replay(&h, 24, true, 100));
    assert(pi_is_replay(&h, 26, true, 120));
    /* DOWN and UP within the same millisecond remain distinct. */
    assert(!pi_is_replay(&h, 26, false, 120));
    assert(pi_is_replay(&h, 26, false, 120));
    assert(!pi_is_replay(&h, 26, true, 121));
    for (int i = 0; i < PI_HISTORY_SIZE; i++) {
        assert(!pi_is_replay(&h, 1, true, 1000 + i));
    }
    assert(pi_is_replay(&h, 1, true, 1000));
    assert(pi_is_replay(&h, 1, true, 1127));
    puts("PASS: combo replay, rapid re-press, equal timestamps, and ring wrap");
}
