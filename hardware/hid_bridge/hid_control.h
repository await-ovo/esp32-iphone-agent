// Mouse/keyboard commands over BLE HID; called only from the Arduino loop.
#pragma once
#include <Arduino.h>

void hid_poll();  // clear held keys on a new HID session, retry failed releases
void hid_release();
String hid_run(const String &line);
