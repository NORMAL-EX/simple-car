import 'package:flutter/services.dart';

/// 原生屏幕常亮控制
class NativeWakelock {
  static const _channel = MethodChannel('com.videostream/wakelock');

  /// 请求必要权限（电池优化白名单 + 修改系统设置）
  static Future<void> requestPermissions() async {
    try {
      await _channel.invokeMethod('requestPermissions');
    } catch (e) {
      print('NativeWakelock requestPermissions 失败: $e');
    }
  }

  /// 启用屏幕常亮（尝试所有可用方式）
  static Future<void> enable() async {
    try {
      await _channel.invokeMethod('enable');
    } catch (e) {
      print('NativeWakelock enable 失败: $e');
    }
  }

  /// 关闭屏幕常亮
  static Future<void> disable() async {
    try {
      await _channel.invokeMethod('disable');
    } catch (e) {
      print('NativeWakelock disable 失败: $e');
    }
  }

  /// 打开系统显示设置（让用户手动设置屏幕超时）
  static Future<void> openDisplaySettings() async {
    try {
      await _channel.invokeMethod('openDisplaySettings');
    } catch (e) {
      print('NativeWakelock openDisplaySettings 失败: $e');
    }
  }

  /// 检查屏幕常亮是否真的生效了
  /// 返回 Map 包含各项检查结果
  static Future<Map<String, dynamic>> checkStatus() async {
    try {
      final result = await _channel.invokeMethod('checkStatus');
      return Map<String, dynamic>.from(result);
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
