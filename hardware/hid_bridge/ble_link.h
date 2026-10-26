// BLE GATT link to the iOS app (docs/ble-protocol.md): cmd/reply, status heartbeat,
// and encrypted HID. h2zero NimBLE-Arduino; build with flash.sh
// (it force-includes nimble_cfg.h, the host buffer sizes).
#pragma once
#include <Arduino.h>

void ble_begin(const String &name);
bool ble_connected();
bool ble_pop_cmd(String &line, uint32_t wait_ms);  // next `cmd` write, oldest first
void ble_reply(const String &line);                // queued
void ble_status(const String &json);               // latest wins
void ble_unpair();

// One encrypted HID host. The session changes on HID changes or a command peer leaving;
// an in-flight gesture must never continue on a newly connected host.
const char *ble_hid_state();  // ok | asleep | off
uint32_t ble_hid_session();  // zero until mouse, keyboard and consumer reports are subscribed
uint32_t ble_hid_generation();  // also changes when HID reconnects between status heartbeats
bool ble_hid_send(uint8_t report, const uint8_t *data, size_t len, uint32_t session);

uint16_t ble_mtu();
uint8_t ble_phy();       // 1 or 2 (Mbit)
uint32_t ble_reply_drops();  // replies that never got out to a subscribed peer
int ble_peers();         // connected centrals
