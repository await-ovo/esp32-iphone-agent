#include "hid_control.h"
#include <esp_task_wdt.h>
#include "ble_link.h"
#include "src/hid/report.h"

const int STEP = 10;
const int STEP_MS = 15;  // pace relative reports, then calibrate iOS's pointer acceleration
const int HOME_REPORTS = 50;
static uint32_t session;
static uint8_t buttons;
static bool releasePending = true;

static bool send(uint8_t report, const uint8_t *data, size_t n) {
  esp_task_wdt_reset();
  if (ble_hid_send(report, data, n, session)) { delay(STEP_MS); return true; }
  releasePending = true;
  return false;
}

static bool mouse(int x = 0, int y = 0, int wheel = 0, int pan = 0) {
  uint8_t report[] = {buttons, (uint8_t)x, (uint8_t)y, (uint8_t)wheel, (uint8_t)pan};
  return send(HID_REPORT_MOUSE, report, sizeof report);
}

void hid_release() { releasePending = true; hid_poll(); }

void hid_poll() {
  uint32_t current = ble_hid_session();
  if (current != session) { session = current; releasePending = true; }
  if (!releasePending) return;
  buttons = 0;
  if (!session) return;
  uint8_t zero[8] = {0};
  // Try each release even if another report failed. Retry on the next loop if necessary.
  bool m = send(HID_REPORT_MOUSE, zero, 5), k = send(HID_REPORT_KEYBOARD, zero, 8), c = send(HID_REPORT_CONSUMER, zero, 2);
  releasePending = !(m && k && c);
}

static bool movePaced(long x, long y, bool scroll = false) {
  while (x || y) {
    int dx = constrain(x, -STEP, STEP), dy = constrain(y, -STEP, STEP);
    if (!(scroll ? mouse(0, 0, dx, dy) : mouse(dx, dy))) return false;
    x -= dx; y -= dy;
  }
  return true;
}

static bool keyboard(const uint8_t report[8]) {
  if (!send(HID_REPORT_KEYBOARD, report, 8)) return false;
  uint8_t zero[8] = {0};
  return send(HID_REPORT_KEYBOARD, zero, sizeof zero);
}

String hid_run(const String &line) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  long a = 0, b = 0;
  int n = sscanf(arg.c_str(), "%ld %ld", &a, &b);
  if (cmd == "ping") return "ok";
  hid_poll();
  if (!session) return "err Bluetooth mouse not ready (pair in AssistiveTouch)";
  if (releasePending) return "err Bluetooth HID release pending";
  bool ok = false;
  if (cmd == "home") {  // slam the pointer into the top-left corner
    ok = true;
    for (int i = 0; i < HOME_REPORTS && ok; i++) ok = mouse(-127, -127);
  } else if (cmd == "move" || cmd == "scroll") {
    if (n != 2 || a < -32767 || a > 32767 || b < -32767 || b > 32767) return "err invalid mouse delta";
    ok = movePaced(a, b, cmd == "scroll");
  } else if (cmd == "press") {
    buttons = 1; ok = mouse();
  } else if (cmd == "release") {
    hid_release(); ok = !releasePending;
  } else if (cmd == "click") {
    buttons = 1; ok = mouse();
    delay(60);
    buttons = 0;
    bool released = mouse();
    ok = ok && released;
  } else if (cmd == "type") {
    // Reject the whole string before typing, so unsupported UTF-8 never produces partial text.
    for (size_t i = 0; i < arg.length(); i++)
      if (!hid_ascii((uint8_t)arg[i])) return "err type supports ASCII only";
    ok = true;
    for (size_t i = 0; i < arg.length() && ok; i++) {
      uint16_t key = hid_ascii((uint8_t)arg[i]);
      uint8_t report[8] = {(uint8_t)(key & 0x100 ? 2 : 0), 0, (uint8_t)key};
      ok = keyboard(report);
    }
  } else if (cmd == "key") {
    uint8_t report[8];
    if (!hid_combo(arg.c_str(), report)) return "err unknown key or too many keys";
    ok = keyboard(report);
  } else if (cmd == "homescreen") {
    uint8_t home[] = {0x23, 0x02}, zero[2] = {0};  // Consumer AC Home (0x0223)
    ok = send(HID_REPORT_CONSUMER, home, sizeof home);
    delay(40);
    bool released = send(HID_REPORT_CONSUMER, zero, sizeof zero);
    ok = ok && released;
  } else return "err unknown command";
  if (!ok) hid_release();
  return ok ? "ok" : "err Bluetooth HID send failed";
}
