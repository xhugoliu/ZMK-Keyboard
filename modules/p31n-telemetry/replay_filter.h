#pragma once
#include <stdbool.h>
#include <stdint.h>

#define PI_HISTORY_SIZE 128
#define PI_KEY_COUNT 31

struct pi_identity {
    int64_t timestamp;
    uint8_t position;
    bool pressed;
    bool valid;
};

struct pi_history {
    struct pi_identity entries[PI_HISTORY_SIZE];
    unsigned int next;
};

/* Combo can re-raise a DOWN after its original UP: key state alone is insufficient. */
static inline bool pi_is_replay(struct pi_history *history, uint8_t position,
                                bool pressed, int64_t timestamp) {
    for (unsigned int i = 0; i < PI_HISTORY_SIZE; i++) {
        const struct pi_identity *entry = &history->entries[i];
        if (entry->valid && entry->position == position &&
            entry->pressed == pressed && entry->timestamp == timestamp) {
            return true;
        }
    }
    history->entries[history->next] = (struct pi_identity){
        .timestamp = timestamp, .position = position, .pressed = pressed, .valid = true};
    history->next = (history->next + 1) % PI_HISTORY_SIZE;
    return false;
}
