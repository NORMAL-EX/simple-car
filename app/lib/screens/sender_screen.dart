import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:location/location.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../services/native_wakelock.dart';
import '../services/webrtc_service.dart';
import '../services/signaling_service.dart';
import '../services/esp32_service.dart';
import '../services/dual_camera_service.dart';

class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> with WidgetsBindingObserver {
  final WebRTCService _webrtcService = WebRTCService();
  final SignalingService _signalingService = SignalingService();
  final Location _location = Location();
  final Battery _battery = Battery();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Esp32Service _esp32Service = Esp32Service();
  final DualCameraService _dualCameraService = DualCameraService();

  String? _qrData;
  String? _ipv6Address;
  String? _deviceId;
  bool _isConnected = false;
  bool _isLoading = true;
  String _statusMessage = '正在初始化...';

  Timer? _gpsTimer;
  Timer? _batteryTimer;
  bool _locationServiceEnabled = false;
  bool _hasLocationPermission = false;
  String _gpsStatus = '未初始化';
  String _gpsDebugInfo = '';
  int _batteryLevel = 0;

  // ESP32状态
  bool _esp32Connected = false;
  int _esp32Battery = -1;

  // 音频播放状态
  String? _currentAudioPath;
  bool _isPlayingAudio = false;

  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
           (1000000 + (DateTime.now().microsecond * 1000)).toRadixString(36);
      await prefs.setString('device_id', id);
    }
    return id;
  }

  @override
  void initState() {
    super.initState();
    NativeWakelock.enable();
    _initializeSender();
  }

  @override
  void dispose() {
    NativeWakelock.disable();

    if (_isConnected) {
      final message = jsonEncode({'type': 'disconnect'});
      _signalingService.sendMessage(message);
    }

    _gpsTimer?.cancel();
    _batteryTimer?.cancel();
    _exitFullscreen();
    _webrtcService.dispose();
    _signalingService.close();
    _audioPlayer.dispose();
    _esp32Service.dispose();
    _dualCameraService.stop();

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  Future<void> _initializeSender() async {
    _setAppOrientation(true);

    try {
      _deviceId = await _getDeviceId();

      setState(() {
        _statusMessage = '正在初始化WebRTC...';
      });

      await _webrtcService.initialize();

      // DataChannel listeners
      _webrtcService.onFileReceived = (name, bytes) async {
        print('Sender: Received file $name (${bytes.length} bytes)');
        await _handleReceivedAudio(name, bytes);
      };

      _webrtcService.onCommandReceived = (cmd) {
        if (cmd == 'stop_audio') {
          _stopAudio();
        } else if (cmd == 'HB') {
          _webrtcService.onHeartbeatReceived();
          _webrtcService.sendDataCommand('HB');
        } else if (cmd.startsWith('RC:')) {
          final rcCmd = cmd.substring(3);
          final match = RegExp(r'S:(\d+),T:(\d+)').firstMatch(rcCmd);
          if (match != null) {
            final steering = int.parse(match.group(1)!);
            final throttle = int.parse(match.group(2)!);
            _esp32Service.sendControl(steering, throttle);
          }
        } else if (cmd == 'ESP32_INIT') {
          print('[Sender] Received ESP32_INIT, connecting BLE...');
          _initEsp32();
        }
      };

      await _initLocationService();

      setState(() {
        _statusMessage = '正在获取IPv6地址...';
      });

      _ipv6Address = await _webrtcService.getIPv6Address();

      if (_ipv6Address == null) {
        setState(() {
          _statusMessage = '无法获取IPv6地址，请检查网络设置';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _statusMessage = '正在启动信令服务...';
      });

      _signalingService.onClientConnected = () async {
        setState(() {
          _statusMessage = '接收端已连接，正在建立视频通道...';
        });
        if (_deviceId != null) {
          final msg = jsonEncode({'type': 'device_info', 'device_id': _deviceId});
          _signalingService.sendMessage(msg);
        }
        await _webrtcService.createSenderConnection();
      };

      _signalingService.onMessage = _handleSignalingMessage;

      await _signalingService.startServer();

      _webrtcService.onLocalDescription = (description) {
        final message = jsonEncode({
          'type': 'offer',
          'sdp': description.sdp,
        });
        _signalingService.sendMessage(message);
      };

      _webrtcService.onIceCandidate = (candidate) {
        final message = jsonEncode({
          'type': 'candidate',
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
        _signalingService.sendMessage(message);
      };

      _webrtcService.onConnectionStateChange = () {
        if (_webrtcService.isConnected && !_isConnected) {
          setState(() {
            _isConnected = true;
            _statusMessage = '连接成功！正在传输视频...';
          });
          _enterFullscreen();
          _startGpsUpdates();
          _startBatteryUpdates();
          _checkAndPromptScreenTimeout();
          print('[Sender] WebRTC connected, auto-init ESP32');
          _initEsp32();
          final msg = jsonEncode({
            'type': 'camera_state',
            'isFront': _webrtcService.isFrontCamera,
          });
          _signalingService.sendMessage(msg);
        }
      };

      final connectionInfo = ConnectionInfo(
        ipv6Address: _ipv6Address!,
        port: _signalingService.port,
      );

      setState(() {
        _qrData = connectionInfo.toEncodedString();
        _isLoading = false;
        _statusMessage = '等待接收端扫码连接...';
      });

    } catch (e) {
      setState(() {
        _statusMessage = '初始化失败: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _handleReceivedAudio(String name, List<int> bytes) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes);

      print('Audio saved to: ${file.path}');
      _currentAudioPath = file.path;

      await _audioPlayer.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: [AVAudioSessionOptions.mixWithOthers, AVAudioSessionOptions.duckOthers],
        ),
      ));

      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(file.path));

      setState(() {
        _isPlayingAudio = true;
      });
      
      _audioPlayer.onPlayerComplete.listen((_) {
        setState(() {
          _isPlayingAudio = false;
        });
      });
      
    } catch (e) {
      print('Error handling received audio: $e');
    }
  }

  Future<void> _stopAudio() async {
    if (_isPlayingAudio) {
      await _audioPlayer.stop();
      setState(() {
        _isPlayingAudio = false;
      });
      print('Audio playback stopped by command');
    }
  }

  Future<void> _initEsp32() async {
    _esp32Service.onConnectionChanged = (connected) {
      setState(() => _esp32Connected = connected);
      final msg = jsonEncode({'type': 'esp32_status', 'connected': connected});
      _signalingService.sendMessage(msg);
    };
    _esp32Service.onBatteryUpdate = (level) {
      setState(() => _esp32Battery = level);
      final msg = jsonEncode({'type': 'esp32_battery', 'level': level});
      _signalingService.sendMessage(msg);
    };
    await _esp32Service.connect();
  }

  Future<void> _initLocationService() async {
    try {
      print('GPS: 开始初始化位置服务...');
      _gpsDebugInfo = '初始化中...\n';
      
      _locationServiceEnabled = await _location.serviceEnabled();
      _gpsDebugInfo += '服务启用: $_locationServiceEnabled\n';
      
      if (!_locationServiceEnabled) {
        _locationServiceEnabled = await _location.requestService();
        _gpsDebugInfo += '请求后服务状态: $_locationServiceEnabled\n';
        
        if (!_locationServiceEnabled) {
          setState(() {
            _gpsStatus = '位置服务未启用';
          });
          return;
        }
      }
      
      var permission = await _location.hasPermission();
      _gpsDebugInfo += '权限: $permission\n';
      
      if (permission == PermissionStatus.denied) {
        permission = await _location.requestPermission();
        _gpsDebugInfo += '请求后权限: $permission\n';
      }
      
      if (permission == PermissionStatus.granted || 
          permission == PermissionStatus.grantedLimited) {
        _hasLocationPermission = true;
        
        await _location.changeSettings(
          accuracy: LocationAccuracy.high,
          interval: 3000,
          distanceFilter: 0,
        );
        
        try {
          final testLocation = await _location.getLocation().timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              throw TimeoutException('获取位置超时 (15秒)');
            },
          );
          
          if (testLocation.latitude != null && testLocation.longitude != null) {
            setState(() {
              _gpsStatus = '已就绪';
              _gpsDebugInfo += '成功: ${testLocation.latitude?.toStringAsFixed(4)}, ${testLocation.longitude?.toStringAsFixed(4)}\n';
            });
          } else {
            setState(() {
              _gpsStatus = '坐标为null';
              _gpsDebugInfo += '位置数据为空\n';
            });
          }
        } catch (e) {
          setState(() {
            _gpsStatus = '定位失败: ${e.toString().substring(0, e.toString().length > 30 ? 30 : e.toString().length)}';
            _gpsDebugInfo += '错误: $e\n';
          });
        }
      } else if (permission == PermissionStatus.deniedForever) {
        _hasLocationPermission = false;
        setState(() {
          _gpsStatus = '权限被永久拒绝';
          _gpsDebugInfo += '权限被永久拒绝\n';
        });
      } else {
        _hasLocationPermission = false;
        setState(() {
          _gpsStatus = '权限被拒绝';
          _gpsDebugInfo += '权限被拒绝: $permission\n';
        });
      }
    } catch (e) {
      setState(() {
        _gpsStatus = '异常';
        _gpsDebugInfo += '异常: $e\n';
      });
      _locationServiceEnabled = false;
      _hasLocationPermission = false;
    }
  }

  void _enterFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _exitFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _checkAndPromptScreenTimeout() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('screen_timeout_prompted') == true) return;

    final status = await NativeWakelock.checkStatus();
    final canWrite = status['canWriteSettings'] == true;
    final timeout = status['currentTimeoutMs'] as int? ?? 0;

    if (canWrite && timeout > 600000) return;

    if (!mounted) return;
    await prefs.setBool('screen_timeout_prompted', true);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('防止屏幕熄灭'),
        content: const Text(
          '部分系统会自动熄灭屏幕。\n\n'
          '请在系统设置中将「休眠」时间改为最长（如30分钟或"永不"），'
          '以确保视频传输期间屏幕不会熄灭。\n\n'
          '点击「前往设置」将打开显示设置页面。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后再说'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              NativeWakelock.openDisplaySettings();
            },
            child: const Text('前往设置'),
          ),
        ],
      ),
    );
  }

  void _startGpsUpdates() {
    if (!_locationServiceEnabled || !_hasLocationPermission) return;
    
    _sendGpsUpdate();
    
    _gpsTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_isConnected && _locationServiceEnabled && _hasLocationPermission) {
        _sendGpsUpdate();
      }
    });
  }
  
  Future<void> _sendGpsUpdate() async {
    try {
      final locationData = await _location.getLocation().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('GPS timeout'),
      );
      if (locationData.latitude != null && locationData.longitude != null) {
        final message = jsonEncode({
          'type': 'gps_update',
          'latitude': locationData.latitude,
          'longitude': locationData.longitude,
          'accuracy': locationData.accuracy ?? 0,
          'altitude': locationData.altitude ?? 0,
          'speed': locationData.speed ?? 0,
          'heading': locationData.heading ?? 0,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        _signalingService.sendMessage(message);
      }
    } catch (e) {
      print('GPS: 发送位置失败: $e');
    }
  }

  void _startBatteryUpdates() {
    _sendBatteryUpdate();
    _batteryTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (_isConnected) {
        _sendBatteryUpdate();
      }
    });
  }

  Future<void> _sendBatteryUpdate() async {
    try {
      final level = await _battery.batteryLevel;
      _batteryLevel = level;
      final message = jsonEncode({
        'type': 'battery_update',
        'level': level,
      });
      _signalingService.sendMessage(message);
    } catch (e) {
      print('Battery: 发送电量失败: $e');
    }
  }

  void _handleSignalingMessage(String message) {
    try {
      final data = jsonDecode(message);
      
      switch (data['type']) {
        case 'answer':
          final description = RTCSessionDescription(
            data['sdp'],
            'answer',
          );
          _webrtcService.setRemoteDescription(description);
          break;
          
        case 'candidate':
          final candidate = RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          );
          _webrtcService.addIceCandidate(candidate);
          break;
          
        case 'resolution_request':
          final resolutionName = data['resolution'] as String;
          final resolution = _webrtcService.supportedResolutions
              .firstWhere((r) => r.name == resolutionName, 
                         orElse: () => _webrtcService.currentResolution);
          _webrtcService.changeResolution(resolution);
          break;
          
        case 'flashlight_toggle':
          _webrtcService.toggleFlashlight().then((success) {
            final msg = jsonEncode({
              'type': 'flashlight_state',
              'isOn': _webrtcService.isFlashlightOn,
            });
            _signalingService.sendMessage(msg);
          });
          break;
          
        case 'camera_switch':
          _webrtcService.switchCamera().then((success) {
            final msg = jsonEncode({
              'type': 'camera_state',
              'isFront': _webrtcService.isFrontCamera,
            });
            _signalingService.sendMessage(msg);
            if (_dualCameraService.onFrame != null) {
              _dualCameraService.start(!_webrtcService.isFrontCamera);
            }
          });
          break;
          
        case 'bitrate_config':
          final level = data['level'] as String;
          _webrtcService.setBitrateLevel(level);
          break;
          
        case 'orientation_config':
          final isLandscape = data['isLandscape'] as bool;
          _webrtcService.setOrientation(isLandscape);
          _setAppOrientation(isLandscape);
          break;

        case 'pip_config':
          final enabled = data['enabled'] as bool;
          if (enabled) {
            _dualCameraService.onFrame = (jpegData) {
              _webrtcService.sendDataCommand('PIP:${base64Encode(jpegData)}');
            };
            _dualCameraService.onError = () {
              final msg = jsonEncode({'type': 'pip_unsupported'});
              _signalingService.sendMessage(msg);
              _dualCameraService.stop();
            };
            _dualCameraService.start(!_webrtcService.isFrontCamera);
          } else {
            _dualCameraService.stop();
          }
          break;
      }
    } catch (e) {
      debugPrint('信令消息处理错误: $e');
    }
  }

  void _setAppOrientation(bool isLandscape) {
    if (isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  Future<bool> _showDisconnectConfirmation() async {
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('确定要断开视频连接吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    
    if (firstConfirm != true) return false;
    
    final secondConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('再次确认'),
        content: const Text('断开后需要重新扫码连接，确定要断开吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确定断开'),
          ),
        ],
      ),
    );
    
    return secondConfirm == true;
  }

  Future<void> _handleBackPress() async {
    if (_isConnected) {
      final shouldDisconnect = await _showDisconnectConfirmation();
      if (shouldDisconnect) {
        final message = jsonEncode({'type': 'disconnect'});
        _signalingService.sendMessage(message);
        
        _exitFullscreen();
        if (mounted) Navigator.pop(context);
      }
    } else {
      Navigator.pop(context);
    }
  }
  
  void _showGpsDebugDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('GPS调试信息'),
        content: SingleChildScrollView(
          child: Text(
            'GPS状态: $_gpsStatus\n'
            '位置服务: $_locationServiceEnabled\n'
            '位置权限: $_hasLocationPermission\n\n'
            '调试日志:\n$_gpsDebugInfo',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _initLocationService();
            },
            child: const Text('重新初始化GPS'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isConnected) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (!didPop) {
            await _handleBackPress();
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.videocam, color: Colors.green, size: 80),
                        SizedBox(height: 20),
                        Text('已连接', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
                        SizedBox(height: 8),
                        Text('视频正在传输中...', style: TextStyle(color: Colors.white70, fontSize: 16)),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: _handleBackPress,
                  ),
                ),
              ),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 8,
                child: GestureDetector(
                  onTap: _showGpsDebugDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.gps_fixed, color: _hasLocationPermission ? Colors.green : Colors.orange, size: 16),
                        const SizedBox(width: 4),
                        Text(
                          _hasLocationPermission ? 'GPS' : 'GPS关闭',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('发送端'),
        backgroundColor: Colors.blue.shade800,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue.shade900, Colors.black],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                color: Colors.orange.shade700,
                child: Row(
                  children: [
                    const Icon(Icons.pending, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_statusMessage, style: const TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: Colors.white),
                            SizedBox(height: 16),
                            Text('正在准备...', style: TextStyle(color: Colors.white70)),
                          ],
                        ),
                      )
                    : _buildQRCode(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQRCode() {
    if (_qrData == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 64),
            const SizedBox(height: 16),
            Text(_statusMessage, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          ],
        ),
      );
    }
    
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableSize = constraints.maxHeight < constraints.maxWidth 
            ? constraints.maxHeight 
            : constraints.maxWidth;
            
        final qrSize = (availableSize * 0.55).clamp(120.0, 300.0);
        
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: _qrData!,
                    version: QrVersions.auto,
                    size: qrSize,
                    backgroundColor: Colors.white,
                  ),
                ),
                SizedBox(height: qrSize < 150 ? 8 : 16),
                Text(
                  '请使用接收端扫描此二维码',
                  style: TextStyle(color: Colors.white, fontSize: qrSize < 150 ? 14 : 18),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _showGpsDebugDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: _hasLocationPermission 
                          ? Colors.green.withOpacity(0.3) 
                          : Colors.orange.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _hasLocationPermission 
                            ? Colors.green.withOpacity(0.5)
                            : Colors.orange.withOpacity(0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _hasLocationPermission ? Icons.gps_fixed : Icons.gps_off,
                          color: _hasLocationPermission ? Colors.green : Colors.orange,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'GPS: $_gpsStatus',
                          style: TextStyle(
                            color: _hasLocationPermission ? Colors.green.shade200 : Colors.orange.shade200,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.info_outline, color: Colors.white.withOpacity(0.5), size: 14),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_ipv6Address != null)
                  Text(
                    'IPv6: $_ipv6Address',
                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
