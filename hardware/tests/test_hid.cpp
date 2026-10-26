#include <cassert>
#include <vector>
#include "../hid_bridge/hid_control.h"
#include "../hid_bridge/src/hid/report.h"

struct Report { uint8_t id; std::vector<uint8_t> data; };
static std::vector<Report> reports;
static uint32_t current;
static int attempts, failAt;
static bool blocked, reconnect;

uint32_t ble_hid_session() { return current; }
bool ble_hid_send(uint8_t id, const uint8_t *p, size_t n, uint32_t session) {
  attempts++;
  if (!session || session != current || blocked || attempts == failAt) return false;
  reports.push_back({id, {p, p + n}});
  if (reconnect) { current++; reconnect = false; }
  return true;
}

static void clear() { reports.clear(); attempts = failAt = 0; }
static void released() {
  assert(reports.size() >= 3);
  for (size_t i = reports.size() - 3; i < reports.size(); i++)
    for (auto b : reports[i].data) assert(b == 0);
}

int main() {
  assert(hid_run("ping") == "ok");
  assert(hid_run("click").find("err") == 0 && reports.empty());
  current = 1;
  hid_poll();
  assert(reports.size() == 3);
  released();

  clear();
  assert(hid_run("move 17 -12") == "ok");
  assert(reports.size() == 2);
  assert((reports[0].data == std::vector<uint8_t>{0, 10, 246, 0, 0}));
  assert((reports[1].data == std::vector<uint8_t>{0, 7, 254, 0, 0}));
  clear();
  assert(hid_run("press") == "ok");
  assert(hid_run("move 1 0") == "ok" && reports.back().data[0] == 1);
  assert(hid_run("release") == "ok");
  released();

  clear();
  assert(hid_run("type A!") == "ok" && reports.size() == 4);
  assert(reports[0].id == HID_REPORT_KEYBOARD && reports[0].data[0] == 2 && reports[0].data[2] == 4);
  assert(reports[1].data == std::vector<uint8_t>(8));
  clear();
  assert(hid_run("type a\xE4\xB8\xAD").find("err") == 0 && reports.empty());
  assert(hid_run("key cmd+unknown").find("err") == 0 && reports.empty());
  assert(hid_run("move 32768 0").find("err") == 0 && reports.empty());
  assert(hid_run("homescreen") == "ok");
  assert(reports[0].id == HID_REPORT_CONSUMER && reports[0].data == std::vector<uint8_t>({0x23, 2}));
  assert(reports[1].data == std::vector<uint8_t>(2));

  // A failed key-up aborts typing and retries all releases before the next command.
  clear(); failAt = 2;
  assert(hid_run("type ab").find("err") == 0);
  assert(reports.size() == 4 && reports[0].data[2] == 4);
  released();

  // If even releases fail, no new gesture is allowed until they can be delivered.
  clear(); blocked = true;
  assert(hid_run("click").find("err") == 0);
  assert(hid_run("press") == "err Bluetooth HID release pending" && reports.empty());
  blocked = false;
  hid_poll(); released();

  // Reconnection halfway through a move sends only release reports to the new session.
  clear(); reconnect = true;
  assert(hid_run("move 30 0").find("err") == 0);
  assert(reports.size() == 4 && reports[0].data[1] == 10);
  released();
  clear(); current = 0; hid_poll();
  assert(hid_run("press").find("err") == 0 && reports.empty());
  current = 10; hid_poll(); released();
  // Losing an app subscription also changes the session while system HID stays connected.
  clear(); assert(hid_run("press") == "ok");
  current++; hid_poll(); released();
  assert(hid_run("move 1 0") == "ok" && reports.back().data[0] == 0);
  puts("HID command tests passed");
}
