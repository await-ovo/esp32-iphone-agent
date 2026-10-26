// BLE GATT link, see ble_link.h. Host: h2zero NimBLE-Arduino 2.5.x, buffer sizes in nimble_cfg.h.
//
// Replies and status use one TX task. HID reports go directly to the encrypted host.
#include "ble_link.h"
#include <atomic>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include "nimble/nimble/host/include/host/ble_hs.h"
#include "src/hid/report.h"

static_assert(MYNEWT_VAL(MSYS_1_BLOCK_COUNT) == 64 && MYNEWT_VAL(MSYS_1_BLOCK_SIZE) == 320,
              "nimble_cfg.h not applied: build with hardware/flash.sh");
static_assert(MYNEWT_VAL(MSYS_2_BLOCK_COUNT) == 0 && MYNEWT_VAL(BLE_TRANSPORT_ACL_FROM_LL_COUNT) == 24, "nimble_cfg.h");
static_assert(MYNEWT_VAL(BLE_ATT_PREFERRED_MTU) == 517 && MYNEWT_VAL(BLE_HS_LOG_LVL) == 5, "nimble_cfg.h");

#define UUID(s) "6e400001-a9e8-4b1b-9c39-6d6f8a3c" s
const size_t CMD_MAX = 512;
const size_t TEXT_MAX = 514;               // MTU 517 - 3
const uint32_t REPLY_TIMEOUT_MS = 3000;    // replies retry this long
const uint32_t STATUS_TIMEOUT_MS = 500;    // a newer status replaces it a second later anyway
const int MBUF_DATA = MYNEWT_VAL(MSYS_1_BLOCK_SIZE) - 16;  // payload per block (16 B mbuf header)
// Up to MAX_PEERS centrals at once: the phone's app, plus a Mac as a debug harness.
const int MAX_PEERS = 2;

enum { CH_REPLY, CH_STATUS, CH_MOUSE, CH_KEYBOARD, CH_CONSUMER, CH_COUNT };

struct Text {
  uint16_t len;
  char s[TEXT_MAX];
};

static NimBLEServer *server;
static NimBLECharacteristic *chars[CH_COUNT], *hidControl, *hidProtocol;
static QueueHandle_t cmdQueue, replyQueue;
static SemaphoreHandle_t statusLock;
static Text statusText;
static bool statusDirty;
static std::atomic<int> ctrlPending;  // replies queued or sending + a status waiting; pending control messages
static volatile int peers[MAX_PEERS] = {-1, -1};
static volatile bool subscribed[MAX_PEERS][CH_COUNT];
static volatile bool encrypted[MAX_PEERS], suspended[MAX_PEERS], bootMode[MAX_PEERS];
static std::atomic<int> hidHost{-1};  // a debug central must never receive the phone's keystrokes
static std::atomic<uint32_t> hidGeneration{1};
static std::atomic<uint32_t> replyDrops;

#if DEBUG_SERIAL
#define BLE_LOG(...) Serial.printf("ble: " __VA_ARGS__)
#else
#define BLE_LOG(...) ((void)0)
#endif

static int slotOf(int h) {
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] == h) return i;
  return -1;
}

// The peer's slot, claimed on first sight: a bonded central's restored subscriptions (and its
// encryption) can be reported before onConnect, and must not be lost.
static int slotFor(int h) {
  int i = slotOf(h);
  if (i < 0 && (i = slotOf(-1)) >= 0) {
    for (int c = 0; c < CH_COUNT; c++) subscribed[i][c] = false;
    encrypted[i] = suspended[i] = bootMode[i] = false;
    peers[i] = h;
  }
  return i;
}

static int peerCount() {
  int n = 0;
  for (int i = 0; i < MAX_PEERS; i++) n += peers[i] >= 0;
  return n;
}

static int indexOf(NimBLECharacteristic *c) {
  for (int i = 0; i < CH_COUNT; i++)
    if (chars[i] == c) return i;
  return -1;
}

static bool anySubscribed(int ch) {
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] >= 0 && subscribed[i][ch]) return true;
  return false;
}

uint32_t ble_hid_session() {
  int h = hidHost;
  int p = h < 0 ? -1 : slotOf(h);
  return p >= 0 && encrypted[p] && !suspended[p] && !bootMode[p] &&
         subscribed[p][CH_MOUSE] && subscribed[p][CH_KEYBOARD] && subscribed[p][CH_CONSUMER]
             ? hidGeneration.load() : 0;
}

uint32_t ble_hid_generation() { return hidGeneration; }

const char *ble_hid_state() {
  if (ble_hid_session()) return "ok";
  int h = hidHost;
  int p = h < 0 ? -1 : slotOf(h);
  return p >= 0 && suspended[p] ? "asleep" : "off";
}

static void logConn(const char *what, NimBLEConnInfo &ci) {
  BLE_LOG("%s conn %u: interval %.2f ms, latency %u, timeout %u ms, mtu %u, %s\n", what, ci.getConnHandle(),
          ci.getConnInterval() * 1.25f, ci.getConnLatency(), ci.getConnTimeout() * 10u, ci.getMTU(),
          ci.isEncrypted() ? (ci.isBonded() ? "encrypted+bonded" : "encrypted") : "plain");
}

// 15 ms interval, no latency, 4 s supervision; reliable 1M PHY; DLE 251.
static void tuneLink(uint16_t h) {
  // Keep the connection on 1M: forcing 2M makes weak links repeatedly time out.
  server->setDataLen(h, 251);
  server->updateConnParams(h, 12, 12, 0, 400);
}

class ServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, NimBLEConnInfo &ci) override {
    if (slotFor(ci.getConnHandle()) < 0) { s->disconnect(ci.getConnHandle()); return; }
    logConn("connect", ci);
    tuneLink(ci.getConnHandle());
    if (peerCount() < MAX_PEERS) NimBLEDevice::startAdvertising();  // room for the debug harness
  }
  void onDisconnect(NimBLEServer *s, NimBLEConnInfo &ci, int reason) override {
    int i = slotOf(ci.getConnHandle());
    bool controller = i >= 0 && subscribed[i][CH_REPLY];
    if (i >= 0) {
      for (int c = 0; c < CH_COUNT; c++) subscribed[i][c] = false;
      encrypted[i] = false;
      peers[i] = -1;
    }
    int h = ci.getConnHandle();
    bool host = hidHost.compare_exchange_strong(h, -1);
    if (host || controller) hidGeneration++;  // release even if another debug/app peer remains
    BLE_LOG("disconnect conn %u, reason 0x%x\n", ci.getConnHandle(), reason);
    NimBLEDevice::startAdvertising();
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo &ci) override { BLE_LOG("conn %u: mtu %u\n", ci.getConnHandle(), mtu); }
  void onConnParamsUpdate(NimBLEConnInfo &ci) override { logConn("params", ci); }
  void onPhyUpdate(NimBLEConnInfo &ci, uint8_t tx, uint8_t rx) override {
    BLE_LOG("conn %u: phy tx %uM rx %uM\n", ci.getConnHandle(), tx, rx);
  }
  void onAuthenticationComplete(NimBLEConnInfo &ci) override {
    int p = slotFor(ci.getConnHandle());
    if (p >= 0) encrypted[p] = ci.isEncrypted();
    logConn("security", ci);
  }
};

class CharCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &ci) override {
    const NimBLEAttValue &raw = c->getValue();
    if (c == hidControl || c == hidProtocol) {
      int p = slotOf(ci.getConnHandle());
      if (p >= 0 && ci.getConnHandle() == hidHost && raw.size() == 1) {
        if (c == hidControl) suspended[p] = raw.data()[0] == 0;
        else bootMode[p] = raw.data()[0] == 0;
        hidGeneration++;  // abort a gesture; clear keys before resuming report mode
      }
      return;
    }
    String v(raw.c_str(), raw.length());
    char line[CMD_MAX] = {0};
    v.trim();
    strncpy(line, v.c_str(), CMD_MAX - 1);
    if (line[0]) xQueueSend(cmdQueue, line, 0);  // full queue: the app times out and retries
  }
  void onSubscribe(NimBLECharacteristic *c, NimBLEConnInfo &ci, uint16_t sub) override {
    int i = indexOf(c), p = sub & 1 ? slotFor(ci.getConnHandle()) : slotOf(ci.getConnHandle());
    // CoreBluetooth may unsubscribe while iOS keeps the same physical link for HID.
    if (i == CH_REPLY && p >= 0 && subscribed[p][i] && !(sub & 1)) hidGeneration++;
    if (i >= CH_MOUSE && p >= 0) {
      int none = -1;
      if (sub & 1) hidHost.compare_exchange_strong(none, ci.getConnHandle());
      if (hidHost != ci.getConnHandle()) {
        if (sub & 1) server->disconnect(ci.getConnHandle());  // only one HID host at a time
        return;
      }
      if (subscribed[p][i] != bool(sub & 1)) hidGeneration++;
    }
    if (i >= 0 && p >= 0) {
      subscribed[p][i] = sub & 1;
      encrypted[p] = ci.isEncrypted();
    }
    BLE_LOG("conn %u: %s %s\n", ci.getConnHandle(), sub & 1 ? "subscribed" : "unsubscribed",
            i == CH_REPLY ? "reply" : i == CH_STATUS ? "status" : "hid");
  }
};

static CharCb charCb;

#if DEBUG_SERIAL
static int onGap(ble_gap_event *e, void *) {  // NimBLEServerCallbacks has no data-length event
  if (e->type == BLE_GAP_EVENT_DATA_LEN_CHG)
    BLE_LOG("data length tx %u B / %u us, rx %u B / %u us\n", e->data_len_chg.max_tx_octets,
            e->data_len_chg.max_tx_time, e->data_len_chg.max_rx_octets, e->data_len_chg.max_rx_time);
  return 0;
}
#endif

// msys blocks one queued notify of n bytes holds: ATT/L2CAP/HCI headers + packet header in the first
// block, plus one for the ACL fragment the host splits off.
static int blocksFor(size_t n) { return (int)((n + 3 + 4 + 4 + 8 + MBUF_DATA - 1) / MBUF_DATA) + 1; }

// One notify through the NimBLE host directly: unlike NimBLECharacteristic::notify() it reports
// "out of buffers", so we can wait instead of silently losing the packet.
static bool notifyOne(int slot, int ch, const uint8_t *p, size_t n, uint32_t start, uint32_t timeout_ms,
                      uint32_t session = 0) {
  int need = blocksFor(n);
  for (;;) {
    if (session && session != ble_hid_session()) return false;
    int h = peers[slot];
    if (h < 0 || !subscribed[slot][ch]) return false;
    if (os_msys_num_free() >= need) {
      os_mbuf *om = ble_hs_mbuf_from_flat(p, n);
      int rc = om ? ble_gatts_notify_custom(h, chars[ch]->getHandle(), om) : BLE_HS_ENOMEM;  // om consumed
      if (rc == 0) return true;
      if (rc != BLE_HS_ENOMEM) {
        BLE_LOG("notify ch %d conn %d failed rc=%d\n", ch, h, rc);
        return false;
      }
    }
    if (millis() - start > timeout_ms) {
      BLE_LOG("notify ch %d conn %d gave up after %lu ms (free %d)\n", ch, h, millis() - start, os_msys_num_free());
      return false;
    }
    vTaskDelay(1);
  }
}

bool ble_hid_send(uint8_t report, const uint8_t *data, size_t len, uint32_t session) {
  if (!session || session != ble_hid_session() || report < HID_REPORT_MOUSE || report > HID_REPORT_CONSUMER) return false;
  int p = slotOf(hidHost);
  if (p < 0) return false;
  ctrlPending++;  // give HID the same buffer reserve and priority as command replies
  bool ok = notifyOne(p, CH_MOUSE + report - HID_REPORT_MOUSE, data, len, millis(), 500, session);
  ctrlPending--;
  return ok;
}

// To every subscribed peer within one deadline; true if at least one got it.
static bool notifyRaw(int ch, const uint8_t *p, size_t n, uint32_t timeout_ms) {
  uint32_t start = millis();
  bool any = false;
  for (int i = 0; i < MAX_PEERS; i++) any |= notifyOne(i, ch, p, n, start, timeout_ms);
  return any;
}

static void sendText(int ch, const Text &t, uint32_t timeout_ms) {
  size_t room = ble_mtu() - 3;
  if (!notifyRaw(ch, (const uint8_t *)t.s, t.len < room ? t.len : room, timeout_ms) && ch == CH_REPLY &&
      anySubscribed(CH_REPLY)) {
    replyDrops++;
    BLE_LOG("reply dropped: %.*s\n", (int)t.len, t.s);
  }
}

static void txTask(void *) {
  static Text t;
  for (;;) {
    if (xQueueReceive(replyQueue, &t, pdMS_TO_TICKS(20)) == pdTRUE) {
      sendText(CH_REPLY, t, REPLY_TIMEOUT_MS);
      ctrlPending--;
    }
    xSemaphoreTake(statusLock, portMAX_DELAY);
    bool due = statusDirty;
    if (due) t = statusText;
    statusDirty = false;
    xSemaphoreGive(statusLock);
    if (due) {
      sendText(CH_STATUS, t, STATUS_TIMEOUT_MS);
      ctrlPending--;
    }
  }
}

static void toText(Text &t, const String &s) {
  t.len = s.length() < TEXT_MAX ? s.length() : TEXT_MAX;
  memcpy(t.s, s.c_str(), t.len);
}

void ble_begin(const String &name) {
  cmdQueue = xQueueCreate(6, CMD_MAX);
  replyQueue = xQueueCreate(8, sizeof(Text));
  statusLock = xSemaphoreCreateMutex();
  NimBLEDevice::init(name.c_str());
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setPower(9);  // dBm: retain link margin during setup, including a board powered by a Mac.
  NimBLEDevice::setDefaultPhy(BLE_GAP_LE_PHY_1M_MASK, BLE_GAP_LE_PHY_1M_MASK);
  NimBLEDevice::setSecurityAuth(true, false, true);  // bonding, Just Works, LE Secure Connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
#if DEBUG_SERIAL
  NimBLEDevice::setCustomGapHandler(onGap);
#endif

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCb());
  NimBLEService *svc = server->createService(UUID("0000"));
  NimBLECharacteristic *cmd = svc->createCharacteristic(UUID("0001"), NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC);
  chars[CH_REPLY] = svc->createCharacteristic(UUID("0002"), NIMBLE_PROPERTY::NOTIFY);
  chars[CH_STATUS] = svc->createCharacteristic(UUID("0003"), NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::READ_ENC);
  auto *hid = new NimBLEHIDDevice(server);
  hid->setReportMap(const_cast<uint8_t *>(hid_report_map), hid_report_map_size);
  hid->setManufacturer("ESP32 Agent");
  hid->setPnp(0x01, 0x02E5, 0, 0x0100);  // Espressif SIG company ID; development product
  hid->setHidInfo(0, 0x02);  // normally connectable, report protocol
  hid->setBatteryLevel(100);  // externally powered; no battery gauge
  chars[CH_MOUSE] = hid->getInputReport(HID_REPORT_MOUSE);
  chars[CH_KEYBOARD] = hid->getInputReport(HID_REPORT_KEYBOARD);
  chars[CH_CONSUMER] = hid->getInputReport(HID_REPORT_CONSUMER);
  hid->getOutputReport(HID_REPORT_KEYBOARD)->setValue(uint8_t(0));  // keyboard LEDs, maintained by iOS
  uint8_t zero[8] = {0};
  chars[CH_MOUSE]->setValue(zero, 5);
  chars[CH_KEYBOARD]->setValue(zero, 8);
  chars[CH_CONSUMER]->setValue(zero, 2);
  hidControl = hid->getHidControl();
  hidProtocol = hid->getProtocolMode();
  hidControl->setCallbacks(&charCb);
  hidProtocol->setCallbacks(&charCb);
  cmd->setCallbacks(&charCb);
  for (auto *c : chars) c->setCallbacks(&charCb);
  server->start();

  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  NimBLEAdvertisementData data, scan;
  data.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  data.setCompleteServices(NimBLEUUID(UUID("0000")));
  data.setCompleteServices(NimBLEUUID(uint16_t(0x1812)));
  data.setAppearance(0x03C1);  // keyboard + mouse are described by the Report Map
  scan.setName(name.c_str());
  adv->setAdvertisementData(data);
  adv->setScanResponseData(scan);
  NimBLEDevice::startAdvertising();
  xTaskCreatePinnedToCore(txTask, "ble_tx", 3072, NULL, 3, NULL, 1);
  Serial.printf("ble: %s, HID and commands ready, mtu %d\n", NimBLEDevice::getVersion(), ble_att_preferred_mtu());
}

bool ble_connected() { return anySubscribed(CH_REPLY); }

bool ble_pop_cmd(String &line, uint32_t wait_ms) {
  char buf[CMD_MAX];
  if (xQueueReceive(cmdQueue, buf, pdMS_TO_TICKS(wait_ms)) != pdTRUE) return false;
  line = buf;
  return true;
}

void ble_reply(const String &line) {
  if (!anySubscribed(CH_REPLY)) return;
  Text t;
  toText(t, line);
  ctrlPending++;
  if (xQueueSend(replyQueue, &t, pdMS_TO_TICKS(200)) != pdTRUE) {  // 8 replies stuck: the link is gone
    ctrlPending--;
    replyDrops++;
  }
}

void ble_status(const String &json) {
  chars[CH_STATUS]->setValue((const uint8_t *)json.c_str(), json.length());  // also served on read
  if (!anySubscribed(CH_STATUS)) return;
  xSemaphoreTake(statusLock, portMAX_DELAY);
  toText(statusText, json);
  if (!statusDirty) ctrlPending++;
  statusDirty = true;
  xSemaphoreGive(statusLock);
}

uint32_t ble_reply_drops() { return replyDrops; }
int ble_peers() { return peerCount(); }

uint16_t ble_mtu() {  // the smallest app peer's; a HID-only connection must not shrink status
  uint16_t mtu = 0;
  for (int i = 0; i < MAX_PEERS; i++) {
    if (!subscribed[i][CH_REPLY] && !subscribed[i][CH_STATUS]) continue;
    int h = peers[i];
    uint16_t m = h >= 0 ? server->getPeerMTU(h) : 0;
    if (m && (!mtu || m < mtu)) mtu = m;
  }
  return mtu ? mtu : 23;
}

uint8_t ble_phy() {
  uint8_t tx = 1, rx = 1;
  int h = peers[0] >= 0 ? peers[0] : peers[1];
  if (h >= 0) ble_gap_read_le_phy(h, &tx, &rx);
  return tx == BLE_GAP_LE_PHY_2M ? 2 : 1;
}

void ble_unpair() {
  for (int i = 0; i < 100 && ctrlPending > 0; i++) vTaskDelay(pdMS_TO_TICKS(10));  // let the `ok` go out
  NimBLEDevice::deleteAllBonds();  // unpairs each bond (also drops it from the controller's resolving list)
  ble_store_clear();               // and any CCCD/peer records left in NVS
  bool any = false;
  for (int i = 0; i < MAX_PEERS; i++)
    if (peers[i] >= 0) { server->disconnect(peers[i]); any = true; }  // onDisconnect restarts advertising
  if (!any) NimBLEDevice::startAdvertising();
}
