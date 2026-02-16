/*
 * RC Car ESP32-C3 Super Mini Controller - BLE版
 *
 * 电路连接:
 * =========
 * GPIO 6 ──> 舵机信号线 (PWM转向)
 * GPIO 7 ──> 电调信号线 (PWM油门)
 * GPIO 3 ──> 电池检测 (100KΩ接电池+, 47KΩ接GND)
 * GND ────> 共地
 *
 * BLE名称: RC_CAR
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVO_PIN 6
#define THROTTLE_PIN 7
#define BATTERY_PIN 3

#define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
#define CHAR_CMD_UUID       "12345678-1234-1234-1234-123456789abd"
#define CHAR_BAT_UUID       "12345678-1234-1234-1234-123456789abe"

BLECharacteristic *pCmdChar, *pBatChar;
bool deviceConnected = false;
unsigned long lastCmd = 0;

uint32_t usToDuty(int us) {
  return (uint32_t)((us / 20000.0f) * 16383);
}

int getBatteryPercent() {
  int raw = analogRead(BATTERY_PIN);
  float v = (raw / 4095.0f) * 3.3f / 0.32f;
  if (v < 6.0f) return 0;
  if (v > 8.4f) return 100;
  return (int)((v - 6.0f) / 2.4f * 100);
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) { deviceConnected = true; Serial.println("[BLE] Connected"); }
  void onDisconnect(BLEServer* s) { deviceConnected = false; Serial.println("[BLE] Disconnected, re-advertising"); BLEDevice::startAdvertising(); }
};

class CmdCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) {
    String cmd = c->getValue().c_str();
    cmd.trim();
    if (cmd.startsWith("S:")) {
      int s, t;
      if (sscanf(cmd.c_str(), "S:%d,T:%d", &s, &t) == 2) {
        Serial.printf("[CMD] S:%d T:%d\n", s, t);
        ledcWrite(0, usToDuty(constrain(s, 1000, 2000)));
        ledcWrite(1, usToDuty(constrain(t, 1000, 2000)));
        lastCmd = millis();
      }
    }
  }
};

void setup() {
  Serial.begin(115200);
  delay(2000);
  Serial.println("[RC_CAR] Booting...");
  analogReadResolution(12);
  ledcSetup(0, 50, 14);
  ledcSetup(1, 50, 14);
  ledcAttachPin(SERVO_PIN, 0);
  ledcAttachPin(THROTTLE_PIN, 1);
  ledcWrite(0, usToDuty(1500));
  ledcWrite(1, usToDuty(1500));

  BLEDevice::init("RC_CAR");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCmdChar = pService->createCharacteristic(CHAR_CMD_UUID, BLECharacteristic::PROPERTY_WRITE_NR); // 无响应写入，更快
  pCmdChar->setCallbacks(new CmdCallbacks());

  pBatChar = pService->createCharacteristic(CHAR_BAT_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pBatChar->addDescriptor(new BLE2902());

  pService->start();
  BLEAdvertising *pAdv = BLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);
  pAdv->setScanResponse(true);
  pAdv->setMinInterval(0x20); // 20ms
  pAdv->setMaxInterval(0x40); // 40ms
  BLEDevice::startAdvertising();
  Serial.println("[RC_CAR] BLE advertising started");
}

void loop() {
  static unsigned long lastBat = 0;
  if (deviceConnected && millis() - lastBat > 1000) {
    char buf[8];
    sprintf(buf, "%d", getBatteryPercent());
    pBatChar->setValue(buf);
    pBatChar->notify();
    lastBat = millis();
  }

  if (millis() - lastCmd > 500) {
    ledcWrite(0, usToDuty(1500));
    ledcWrite(1, usToDuty(1500));
  }

  delay(10);
}
