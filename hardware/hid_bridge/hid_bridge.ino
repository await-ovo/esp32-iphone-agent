// Bluetooth HID bridge. The iPhone captures its own screen; this board only executes input.
// Protocol: docs/ble-protocol.md.
//
// HID commands (unchanged from the old TCP protocol, the board answers "ok" or "err <why>"):
//   ping | home | move <dx> <dy> | press | release | click
//   scroll <v> <h> | type <ascii text> | key <combo, e.g. cmd+h, enter>
//   homescreen (the consumer-control Home key, "AC Home": iOS goes to the Home Screen, like a keyboard's home key)

#include <esp_task_wdt.h>
#include <esp_mac.h>
#include "hid_control.h"
#include "ble_link.h"

#ifndef DEBUG_SERIAL
#define DEBUG_SERIAL 0
#endif

const int WATCHDOG_MS = 8000;
static String receiverName = "ESP32 Agent";

const char *resetReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return "power-on";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_TASK_WDT: case ESP_RST_INT_WDT: case ESP_RST_WDT: return "watchdog";
    case ESP_RST_PANIC: return "crash";
    case ESP_RST_SW: return "software";
    case ESP_RST_USB: return "usb";
    default: return "other";
  }
}

// Board-level commands from the app; everything else is an HID command for run().
String board(const String &line, const String &id) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  if (cmd == "status") return String("ok ") + statusJson(true);
  if (cmd == "app" || cmd == "log") {  // debug relay: Mac -> app ("app run ...") and app -> Mac ("log ...")
    ble_reply(cmd + " " + arg);         // every peer sees it; each side ignores lines it doesn't handle
    return "ok";
  }
  if (cmd == "unpair") {
    ble_reply(id + " ok");  // answer before the link goes down
    ble_unpair();
    return "";
  }
  return hid_run(line);
}

String statusJson(bool full) {
  char s[256];
  snprintf(s, sizeof s,
           "{\"up\":%lu,\"rst\":\"%s\",\"heap\":%u,\"hid\":\"%s\",\"hgen\":%lu,"
           "\"ble\":{\"mtu\":%u,\"phy\":%u,\"rdrop\":%lu,\"n\":%d}}",
           millis(), resetReason(), (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
           ble_hid_state(), (unsigned long)ble_hid_generation(), ble_mtu(), ble_phy(),
           (unsigned long)ble_reply_drops(), ble_peers());
  return s;
}

void statusTask(void *) {
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(1000));
    if (!ble_connected()) continue;
    String s = statusJson(true);
    if (s.length() > ble_mtu() - 3u) s = statusJson(false);
    ble_status(s);
  }
}

void logLine(const char *msg) {
#if DEBUG_SERIAL
  Serial.printf("[%lu] %s\n", millis(), msg);
#endif
}

void setup() {
  Serial.begin(115200);
#if DEBUG_SERIAL
  for (int i = 0; i < 30 && !Serial; i++) delay(100);  // give a serial monitor 3 s to catch the boot lines
#endif
  esp_task_wdt_config_t wdt = {.timeout_ms = WATCHDOG_MS, .idle_core_mask = 0, .trigger_panic = true};
  esp_task_wdt_reconfigure(&wdt);
  esp_task_wdt_add(NULL);

  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_BT);
  char suffix[5];
  snprintf(suffix, sizeof suffix, "%02X%02X", mac[4], mac[5]);
  ble_begin("ESP32 Agent " + String(suffix));
  xTaskCreatePinnedToCore(statusTask, "status", 4096, NULL, 1, NULL, 1);
  Serial.printf("boot %s: free internal heap %u (largest %u), PSRAM %u, reset %s\n", receiverName.c_str(),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM), resetReason());
}

void loop() {
  static bool linked = false;
  esp_task_wdt_reset();
  hid_poll();
  if (linked && !ble_connected()) {
    hid_release();  // the app may disconnect while the system keeps its HID connection
  }
  linked = ble_connected();

  String line;
  if (Serial.available()) {  // UART takes the same `<id> <command>` lines, for debugging from a Mac
    line = Serial.readStringUntil('\n');
    line.trim();
    int sp = line.indexOf(' ');
    String id = sp < 0 ? line : line.substring(0, sp);
    Serial.println(id + " " + board(sp < 0 ? "" : line.substring(sp + 1), id));
    return;
  }
  if (!ble_pop_cmd(line, 50)) return;
  int sp = line.indexOf(' ');
  String id = sp < 0 ? line : line.substring(0, sp);
  String rest = sp < 0 ? "" : line.substring(sp + 1);
  rest.trim();
#if DEBUG_SERIAL
  unsigned long started = millis();
#endif
  String reply = id.toInt() || id == "0" ? board(rest, id) : "err missing request id";
  if (reply.length()) ble_reply(id + " " + reply);
#if DEBUG_SERIAL
  Serial.printf("%s -> %s (%lu ms)\n", line.c_str(), reply.c_str(), millis() - started);
#endif
}
