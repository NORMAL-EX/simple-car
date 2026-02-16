import 'dart:typed_data';
import 'package:flutter/services.dart';

class DualCameraService {
  static const _channel = MethodChannel('com.videostream/dualcam');
  Function(Uint8List)? onFrame;
  Function()? onError;

  DualCameraService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFrame' && call.arguments is Uint8List) {
        onFrame?.call(call.arguments as Uint8List);
      } else if (call.method == 'onError') {
        print('DualCameraService: 双摄像头不支持');
        onError?.call();
      }
    });
  }

  Future<void> start(bool useFront) async {
    print('DualCameraService: start() called, useFront=$useFront');
    try {
      await _channel.invokeMethod('start', {'useFront': useFront});
    } catch (e) {
      print('DualCameraService: start() error: $e');
      onError?.call();
    }
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }
}
