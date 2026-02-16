import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/native_wakelock.dart';
import 'sender_screen.dart';
import 'receiver_screen.dart';

class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key});

  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}

class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  bool _isLoading = false;

  Future<bool> _requestPermissions() async {
    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    final locationStatus = await Permission.location.request();
    // 通知权限（Android 13+ / HarmonyOS 4 必须运行时请求，否则前台服务通知不显示）
    await Permission.notification.request();
    // 请求电池优化白名单 + 修改系统设置权限（原生弹窗）
    await NativeWakelock.requestPermissions();

    return cameraStatus.isGranted && micStatus.isGranted;
  }

  Future<void> _navigateToRole(bool isSender) async {
    setState(() => _isLoading = true);
    
    final hasPermissions = await _requestPermissions();
    
    setState(() => _isLoading = false);
    
    if (!hasPermissions) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('需要相机和麦克风权限才能使用此功能'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => isSender 
              ? const SenderScreen() 
              : const ReceiverScreen(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: _isLoading
              ? const CircularProgressIndicator(color: Colors.blue)
              : Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Logo图标
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.videocam,
                          size: 64,
                          color: Colors.grey.shade800,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '视频图传',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请选择角色',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 60),
                      // 发送端按钮
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: () => _navigateToRole(true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.camera_alt),
                              SizedBox(width: 12),
                              Text(
                                '发送端',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 接收端按钮
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: () => _navigateToRole(false),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.qr_code_scanner),
                              SizedBox(width: 12),
                              Text(
                                '接收端',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
