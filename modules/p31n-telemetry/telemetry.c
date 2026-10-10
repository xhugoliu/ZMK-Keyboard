#include <string.h>
#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/random/random.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/bluetooth/gatt.h>
#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/position_state_changed.h>
#include <zmk/events/ble_active_profile_changed.h>
#include "replay_filter.h"

#define PI_UUID(n) BT_UUID_128_ENCODE(n, 0x5b5a, 0x4b4d, 0x9a6e, 0x5033314e0001)
#define PI_PACKET_SIZE 20
#define PI_STATUS_SIZE 32

struct pi_packet { uint8_t bytes[PI_PACKET_SIZE]; };
K_MSGQ_DEFINE(pi_queue, sizeof(struct pi_packet), 128, 4);

static struct k_spinlock state_lock;
static struct pi_history history;
static bool enabled;
static uint32_t boot_id, session, sequence;
static uint32_t captured, sent, dropped, replayed;

static void stop_capture(void) {
    k_spinlock_key_t key = k_spin_lock(&state_lock);
    enabled = false;
    k_spin_unlock(&state_lock, key);
    k_msgq_purge(&pi_queue);
}

static void ccc_changed(const struct bt_gatt_attr *attr, uint16_t value) {
    ARG_UNUSED(attr);
    if (!(value & BT_GATT_CCC_NOTIFY)) {
        stop_capture();
    }
}

static ssize_t read_status(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                           void *buf, uint16_t len, uint16_t offset) {
    uint8_t bytes[PI_STATUS_SIZE] = {1};
    k_spinlock_key_t key = k_spin_lock(&state_lock);
    bytes[1] = enabled;
    sys_put_le32(boot_id, &bytes[4]);
    sys_put_le32(session, &bytes[8]);
    sys_put_le32(captured, &bytes[12]);
    sys_put_le32(sent, &bytes[16]);
    sys_put_le32(dropped, &bytes[20]);
    sys_put_le32(replayed, &bytes[24]);
    sys_put_le32(sequence, &bytes[28]);
    k_spin_unlock(&state_lock, key);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, bytes, sizeof(bytes));
}

static ssize_t write_control(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags);

BT_GATT_SERVICE_DEFINE(
    pi_service,
    BT_GATT_PRIMARY_SERVICE(BT_UUID_DECLARE_128(PI_UUID(0xa0310000))),
    BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(PI_UUID(0xa0310001)), BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_NONE, NULL, NULL, NULL),
    BT_GATT_CCC(ccc_changed, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
    BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(PI_UUID(0xa0310002)),
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           read_status, write_control, NULL));

static ssize_t write_control(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags) {
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);
    if (offset != 0 || len != 1 || *(const uint8_t *)buf > 1) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }
    struct bt_conn *active = zmk_ble_active_profile_conn();
    bool authorized = active && active == conn;
    if (active) { bt_conn_unref(active); }
    if (!authorized) { return BT_GATT_ERR(BT_ATT_ERR_AUTHORIZATION); }
    bool start = *(const uint8_t *)buf == 1;
    if (start && !bt_gatt_is_subscribed(conn, &pi_service.attrs[2], BT_GATT_CCC_NOTIFY)) {
        return BT_GATT_ERR(BT_ATT_ERR_CCC_IMPROPER_CONF);
    }
    stop_capture();
    if (start) {
        k_spinlock_key_t key = k_spin_lock(&state_lock);
        session++;
        sequence = captured = sent = dropped = replayed = 0;
        memset(&history, 0, sizeof(history));
        enabled = true;
        k_spin_unlock(&state_lock, key);
    }
    return len;
}

static int pi_listener(const zmk_event_t *event) {
    if (as_zmk_ble_active_profile_changed(event)) {
        /* Includes active-host disconnection/reconnection: require a fresh START. */
        stop_capture();
        return ZMK_EV_EVENT_BUBBLE;
    }
    const struct zmk_position_state_changed *ev = as_zmk_position_state_changed(event);
    if (!ev || ev->source != ZMK_POSITION_STATE_CHANGE_SOURCE_LOCAL ||
        ev->position >= PI_KEY_COUNT) {
        return ZMK_EV_EVENT_BUBBLE;
    }
    struct pi_packet packet = {.bytes = {1}};
    k_spinlock_key_t key = k_spin_lock(&state_lock);
    if (!enabled) {
        k_spin_unlock(&state_lock, key);
        return ZMK_EV_EVENT_BUBBLE;
    }
    if (pi_is_replay(&history, ev->position, ev->state, ev->timestamp)) {
        replayed++;
        k_spin_unlock(&state_lock, key);
        return ZMK_EV_EVENT_BUBBLE;
    }
    packet.bytes[1] = ev->position;
    packet.bytes[2] = ev->state;
    sys_put_le32(sequence++, &packet.bytes[4]);
    sys_put_le32((uint32_t)ev->timestamp, &packet.bytes[8]);
    sys_put_le32(boot_id, &packet.bytes[12]);
    sys_put_le32(session, &packet.bytes[16]);
    captured++;
    k_spin_unlock(&state_lock, key);
    /* K_NO_WAIT: transport congestion must never block keyboard processing.
     * Keep kernel queue operations outside our state spinlock. */
    if (k_msgq_put(&pi_queue, &packet, K_NO_WAIT) != 0) {
        key = k_spin_lock(&state_lock);
        if (session == sys_get_le32(&packet.bytes[16])) { dropped++; }
        k_spin_unlock(&state_lock, key);
    }
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(pi_probe, pi_listener);
ZMK_SUBSCRIPTION(pi_probe, zmk_position_state_changed);
ZMK_SUBSCRIPTION(pi_probe, zmk_ble_active_profile_changed);

static void pi_tx_thread(void *a, void *b, void *c) {
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
    struct pi_packet packet;
    while (true) {
        k_msgq_get(&pi_queue, &packet, K_FOREVER);
        uint32_t packet_session = sys_get_le32(&packet.bytes[16]);
        k_spinlock_key_t key = k_spin_lock(&state_lock);
        bool current = enabled && session == packet_session;
        k_spin_unlock(&state_lock, key);
        if (!current) { continue; }
        struct bt_conn *conn = zmk_ble_active_profile_conn();
        int result = -ENOTCONN;
        if (conn) {
            if (bt_gatt_is_subscribed(conn, &pi_service.attrs[2], BT_GATT_CCC_NOTIFY)) {
                result = bt_gatt_notify(conn, &pi_service.attrs[2], packet.bytes, sizeof(packet.bytes));
            }
            bt_conn_unref(conn);
        }
        key = k_spin_lock(&state_lock);
        if (session == packet_session) {
            if (result == 0) { sent++; } else { dropped++; }
        }
        k_spin_unlock(&state_lock, key);
    }
}

/* A separate lower-priority thread isolates GATT's potential backpressure. */
K_THREAD_DEFINE(pi_tx, 1536, pi_tx_thread, NULL, NULL, NULL, 10, 0, 0);

static int pi_init(void) {
    boot_id = sys_rand32_get();
    return 0;
}
SYS_INIT(pi_init, APPLICATION, 90);
