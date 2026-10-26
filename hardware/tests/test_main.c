// Host unit tests for the board's pure-C parts: HID report encoding.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../hid_bridge/src/hid/report.h"

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); } } while (0)

static void test_hid_keyboard(void) {
  // Every printable ASCII character has a keyboard usage. UTF-8 bytes do not.
  for (int c = 32; c < 127; c++) CHECK(hid_ascii((uint8_t)c) != 0);
  for (int c = 128; c < 256; c++) CHECK(hid_ascii((uint8_t)c) == 0);
  CHECK(hid_ascii('a') == 0x04 && hid_ascii('A') == 0x104);
  CHECK(hid_ascii('0') == 0x27 && hid_ascii(')') == 0x127);
  CHECK(hid_ascii('!') == 0x11E && hid_ascii('"') == 0x134);
  CHECK(hid_ascii('\\') == 0x31 && hid_ascii('|') == 0x131);
  CHECK(hid_ascii('\n') == 0x28 && hid_ascii('\t') == 0x2B);
  uint8_t report[8];
  CHECK(hid_combo("cmd+shift+h", report));
  CHECK(report[0] == 10 && report[1] == 0 && report[2] == 0x0B && report[3] == 0);
  CHECK(hid_combo("ctrl+A", report) && report[0] == 3 && report[2] == 4);
  CHECK(hid_combo("up", report) && report[0] == 0 && report[2] == 0x52);
  CHECK(hid_combo("cmd+a+a", report) && report[3] == 0);  // duplicate keys occupy one slot
  CHECK(hid_combo("a+b+c+d+e+f", report) && report[7] == 9);
  // Invalid combinations never change the output, so validation cannot partially press modifiers.
  uint8_t before[8];
  memset(report, 0xA5, sizeof report);
  memcpy(before, report, sizeof before);
  const char *bad[] = {"", "+a", "cmd+", "ctrl++a", "cmd+unknown", "a+b+c+d+e+f+g", "cmd+\xE4\xB8\xAD"};
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
    CHECK(!hid_combo(bad[i], report));
    CHECK(!memcmp(report, before, sizeof report));
  }
}

static void test_hid_report_sizes(void) {
  // Parse HID short items: the declared report sizes must match the bytes sent over GATT.
  unsigned bits[4] = {0}, size = 0, count = 0, id = 0;
  for (size_t i = 0; i < hid_report_map_size;) {
    uint8_t tag = hid_report_map[i++];
    size_t n = tag & 3;
    if (n == 3) n = 4;
    CHECK(i + n <= hid_report_map_size);
    if (i + n > hid_report_map_size) break;
    unsigned value = 0;
    for (size_t j = 0; j < n; j++) value |= (unsigned)hid_report_map[i++] << (8 * j);
    switch (tag & 0xFC) {
      case 0x74: size = value; break;
      case 0x94: count = value; break;
      case 0x84: id = value; CHECK(id > 0 && id < 4); break;
      case 0x80: if (id < 4) bits[id] += size * count; break;
    }
  }
  CHECK(bits[HID_REPORT_MOUSE] == 40);
  CHECK(bits[HID_REPORT_KEYBOARD] == 64);
  CHECK(bits[HID_REPORT_CONSUMER] == 16);
}

int main(void) {
  test_hid_keyboard();
  test_hid_report_sizes();
  printf(fails ? "%d FAILED\n" : "all tests passed\n", fails);
  return fails != 0;
}
