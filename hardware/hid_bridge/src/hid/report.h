// BLE HID report IDs and US keyboard encoding, shared with the host tests.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { HID_REPORT_MOUSE = 1, HID_REPORT_KEYBOARD = 2, HID_REPORT_CONSUMER = 3 };
extern const uint8_t hid_report_map[];
extern const size_t hid_report_map_size;

// Low byte: keyboard usage; bit 8: left Shift. Zero means unsupported.
uint16_t hid_ascii(uint8_t c);
// Parse the whole combination before sending any keys. Output is an 8-byte keyboard report.
bool hid_combo(const char *combo, uint8_t report[8]);

#ifdef __cplusplus
}
#endif
