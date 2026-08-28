/* SPDX-License-Identifier: GPL-2.0-or-later
 * NuphyBar Halo75 V2 ANSI QMK adapter.
 */
#include "agent_light.h"

#include "effect_model.h"
#include "raw_hid.h"
#include "rgb_matrix.h"
#include "timer.h"

#define HALO75_LEFT_LIGHT_INDEX 83
#define ACTIVE_STATE_TIMEOUT_MS (15UL * 60UL * 1000UL)
#define TERMINAL_STATE_TIMEOUT_MS (20UL * 1000UL)

static agent_light_state_t current_state = AGENT_LIGHT_IDLE;
static uint32_t state_started_at;

bool agent_light_handle_via_command(uint8_t *data, uint8_t length) {
    agent_light_state_t next_state;
    if (!agent_light_decode_report(data, length, &next_state)) return false;

    current_state = next_state;
    state_started_at = timer_read32();
    data[3] |= 0x80;
    data[AGENT_LIGHT_REPORT_SIZE - 1] = 0;
    for (uint8_t i = 0; i < AGENT_LIGHT_REPORT_SIZE - 1; i++) {
        data[AGENT_LIGHT_REPORT_SIZE - 1] ^= data[i];
    }
    raw_hid_send(data, length);
    return true;
}

void agent_light_render_overlay(void) {
    if (current_state == AGENT_LIGHT_IDLE) return;

    uint32_t elapsed_ms = timer_elapsed32(state_started_at);
    uint32_t timeout_ms = current_state == AGENT_LIGHT_COMPLETE || current_state == AGENT_LIGHT_ERROR
        ? TERMINAL_STATE_TIMEOUT_MS
        : ACTIVE_STATE_TIMEOUT_MS;
    if (elapsed_ms > timeout_ms) {
        current_state = AGENT_LIGHT_IDLE;
        return;
    }

    agent_light_frame_t frame;
    if (!agent_light_model_render(current_state, elapsed_ms, &frame)) return;
    for (uint8_t i = 0; i < 5; i++) {
        rgb_matrix_set_color(
            HALO75_LEFT_LIGHT_INDEX + i,
            frame.pixel[i].red,
            frame.pixel[i].green,
            frame.pixel[i].blue
        );
    }
}

bool via_command_kb(uint8_t *data, uint8_t length) {
    return agent_light_handle_via_command(data, length);
}
