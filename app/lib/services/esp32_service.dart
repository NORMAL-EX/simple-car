import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class Esp32Service {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothCharacteristic? _rxChar;
  bool _isConnected = false;
  bool _isConnecting = false;
  int _batteryLevel = -1;
  Timer? _pingTimer;
  StreamSubscription? _subscription;

  Function(bool)? onConnectionChanged;
  Function(int)? onBatteryUpdate;

  bool get isConnected => _isConnected;
  int get batteryLevel => _batteryLevel;

  static const String serviceUuid = "12345678-1234-1234-1234-123456789abc";
  static const String cmdCharUuid = "12345678-1234-1234-1234-123456789abd";
  static const String batCharUuid = "12345678-1234-1234-1234-123456789abe";

  Future<void> connect() async {
    if (_isConnected || _isConnecting) {
      print('[ESP32] Already connected/connecting, skip');
      return;
    }
    _isConnecting = true;
    try {
      print('[ESP32] Starting BLE scan...');
      final completer = Completer<void>();
      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          if (r.device.platformName == 'RC_CAR') {
            _device = r.device;
            FlutterBluePlus.stopScan();
            if (!completer.isCompleted) completer.complete();
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      // 等设备找到或扫描超时
      await completer.future.timeout(const Duration(seconds: 9), onTimeout: () {});
      await subscription.cancel();

      if (_device == null) {
        print('[ESP32] RC_CAR not found');
        onConnectionChanged?.call(false);
        return;
      }
      print('[ESP32] Found RC_CAR, connecting...');

      await _device!.connect(timeout: const Duration(seconds: 10));
      print('[ESP32] Connected, discovering services...');
      final services = await _device!.discoverServices();
      print('[ESP32] Found ${services.length} services');

      for (final s in services) {
        print('[ESP32] Service: ${s.uuid}');
        if (s.uuid.toString().toLowerCase() == serviceUuid) {
          print('[ESP32] Matched target service!');
          for (final c in s.characteristics) {
            final uuid = c.uuid.toString().toLowerCase();
            print('[ESP32] Char: $uuid');
            if (uuid == cmdCharUuid) {
              _txChar = c;
              print('[ESP32] CMD char found');
            } else if (uuid == batCharUuid) {
              _rxChar = c;
              try {
                await c.setNotifyValue(true);
                _subscription = c.onValueReceived.listen(_onData);
                print('[ESP32] BAT notify enabled');
              } catch (e) {
                print('[ESP32] BAT notify failed: $e');
              }
            }
          }
        }
      }

      _isConnected = true;
      _isConnecting = false;
      onConnectionChanged?.call(true);

      _device!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _onDisconnect();
        }
      });
    } catch (e) {
      print('[ESP32] Connection error: $e');
      _isConnected = false;
      _isConnecting = false;
      onConnectionChanged?.call(false);
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 1), (_) => _send('PING'));
  }

  void _onData(List<int> data) {
    final line = utf8.decode(data).trim();
    _batteryLevel = int.tryParse(line) ?? -1;
    onBatteryUpdate?.call(_batteryLevel);
  }

  void _onDisconnect() {
    _isConnected = false;
    _batteryLevel = -1;
    onConnectionChanged?.call(false);
  }

  Future<void> _send(String msg) async {
    if (_txChar != null && _isConnected) {
      await _txChar!.write(utf8.encode('$msg\n'), withoutResponse: true);
    }
  }

  void sendControl(int steering, int throttle) {
    _send('S:$steering,T:$throttle');
  }

  void dispose() {
    _pingTimer?.cancel();
    _subscription?.cancel();
    _device?.disconnect();
  }
}
