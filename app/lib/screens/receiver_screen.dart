import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../services/native_wakelock.dart';
import '../services/webrtc_service.dart';
import '../services/signaling_service.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final WebRTCService _webrtcService = WebRTCService();
  final SignalingService _signalingService = SignalingService();
  final MobileScannerController _scannerController = MobileScannerController(
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  final MapController _mapController = MapController();
  
  bool _isScanning = true;
  bool _isConnected = false;
  bool _isConnecting = false;
  String _statusMessage = '请扫描发送端的二维码';
  
  // 音频控制
  bool _isAudioMuted = false;
  bool _isPttPressed = false;
  bool _isSendingFile = false;
  
  // 远程控制状态
  bool _isFlashlightOn = false;
  
  // 延迟显示
  int _latencyMs = 0;
  Timer? _latencyTimer;
  
  // 分辨率
  List<VideoResolution> _availableResolutions = VideoResolution.presets;
  VideoResolution _currentResolution = VideoResolution.presets[1];
  
  // GPS位置
  LatLng? _senderLocation;
  bool _showMiniMap = false;
  bool _showFullMap = false;
  double _gpsSpeed = 0;
  
  // 电量
  int _senderBatteryLevel = -1;

  // ESP32状态
  bool _esp32Connected = false;
  int _esp32Battery = -1;

  // 设置
  bool _showSpeedDisplay = true;
  bool _useKmh = true;
  String _bitrateLevel = 'high';
  bool _isLandscape = true;
  bool _showPipWindow = false;
  bool _pipSupported = true;
  bool _isFrontCamera = false;
  int _steeringStrength = 500;
  int _throttleStrength = 500;
  double _playbackVolume = 1.0;
  String _joystickMode = 'single';
  Uint8List? _pipFrameData;

  @override
  void initState() {
    super.initState();
    NativeWakelock.enable();
    _initializeReceiver();
  }

  Future<void> _initializeReceiver() async {
    await _webrtcService.initialize();
    await _loadSettings();
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

  void _startLatencyUpdates() {
    _latencyTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isConnected) {
        final latency = await _webrtcService.getLatency();
        if (mounted) {
          setState(() {
            _latencyMs = latency;
          });
        }
      }
    });
  }

  Future<void> _handleQRCode(String data) async {
    if (_isConnecting || _isConnected) return;
    
    setState(() {
      _isConnecting = true;
      _isScanning = false;
      _statusMessage = '正在连接...';
    });

    try {
      final connectionInfo = ConnectionInfo.fromEncodedString(data);
      
      setState(() {
        _statusMessage = '正在连接到 ${connectionInfo.ipv6Address}...';
      });

      _signalingService.onMessage = _handleSignalingMessage;
      
      _signalingService.onClientConnected = () {
        setState(() {
          _statusMessage = '信令连接成功，等待视频流...';
        });
      };

      await _signalingService.connectToServer(
        connectionInfo.ipv6Address,
        connectionInfo.port,
      );

      _webrtcService.onLocalDescription = (description) {
        final message = jsonEncode({
          'type': 'answer',
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

      _webrtcService.onRemoteStream = (stream) {
        setState(() {
          _isConnected = true;
          _isConnecting = false;
          _statusMessage = '连接成功！正在接收视频...';
          _pipSupported = true;
          _pipFrameData = null;
        });
        _enterFullscreen();
        NativeWakelock.enable();
        _checkAndPromptScreenTimeout();
        _startLatencyUpdates();
        _webrtcService.sendDataCommand('ESP32_INIT');
        _webrtcService.startHeartbeat();
        _webrtcService.setRemoteAudioVolume(_playbackVolume);
      };

      _webrtcService.onConnectionStateChange = () {
        if (_webrtcService.isConnected && !_isConnected) {
          setState(() {
            _isConnected = true;
            _isConnecting = false;
            _statusMessage = '连接成功！';
          });
          _enterFullscreen();
          NativeWakelock.enable();
          _checkAndPromptScreenTimeout();
          _startLatencyUpdates();
        }
      };

      _webrtcService.onCommandReceived = (cmd) {
        if (cmd == 'HB') {
          _webrtcService.onHeartbeatReceived();
        } else if (cmd.startsWith('PIP:')) {
          try {
            final b64 = cmd.substring(4);
            setState(() => _pipFrameData = base64Decode(b64));
          } catch (_) {}
        }
      };

      _webrtcService.onReconnecting = (attempt) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('连接不稳定，正在重连... ($attempt/3)'), duration: const Duration(seconds: 2)),
          );
        }
      };

      _webrtcService.onHeartbeatTimeout = () {
        if (mounted) {
          _webrtcService.stopHeartbeat();
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('连接已断开'),
              content: const Text('与发送端的连接已丢失，请重新扫码连接。'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _isConnected = false;
                      _isScanning = true;
                      _statusMessage = '请扫描发送端的二维码';
                    });
                    _exitFullscreen();
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        }
      };

    } catch (e) {
      setState(() {
        _isConnecting = false;
        _isScanning = true;
        _statusMessage = '连接失败: $e\n请重新扫码';
      });
    }
  }

  void _handleSignalingMessage(String message) {
    try {
      final data = jsonDecode(message);
      
      switch (data['type']) {
        case 'offer':
          final description = RTCSessionDescription(data['sdp'], 'offer');
          if (_isConnected) {
            _webrtcService.handleRenegotiation(description);
          } else {
            _webrtcService.createReceiverConnection(description);
          }
          break;
          
        case 'candidate':
          final candidate = RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']);
          _webrtcService.addIceCandidate(candidate);
          break;
          
        case 'disconnect':
          _webrtcService.clearRemoteStream();
          setState(() {
            _isConnected = false;
            _isScanning = true;
            _senderLocation = null;
            _showMiniMap = false;
            _showFullMap = false;
            _statusMessage = '发送端已断开，请重新扫码';
          });
          _exitFullscreen();
          NativeWakelock.enable();
          break;
          
        case 'flashlight_state':
          setState(() { _isFlashlightOn = data['isOn'] as bool; });
          break;

        case 'camera_state':
          setState(() { _isFrontCamera = data['isFront'] as bool; });
          break;
          
        case 'gps_update':
          try {
            final lat = data['latitude'];
            final lng = data['longitude'];
            final speed = data['speed'];
            if (lat != null && lng != null) {
              final newLocation = LatLng(
                (lat is int) ? lat.toDouble() : lat as double,
                (lng is int) ? lng.toDouble() : lng as double,
              );
              setState(() {
                _senderLocation = newLocation;
                if (speed != null) {
                  _gpsSpeed = (speed is int) ? speed.toDouble() : speed as double;
                }
              });
              if (_showFullMap) {
                try { _mapController.move(newLocation, _mapController.camera.zoom); } catch (_) {}
              }
            }
          } catch (e) {
            print('GPS接收: 解析位置数据错误: $e');
          }
          break;
          
        case 'battery_update':
          final level = data['level'];
          if (level != null) {
            setState(() {
              _senderBatteryLevel = (level is int) ? level : (level as double).toInt();
            });
          }
          break;

        case 'esp32_status':
          final connected = data['connected'] == true;
          setState(() => _esp32Connected = connected);
          if (!connected && _isConnected) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('ESP32连接断开，车辆控制不可用'), backgroundColor: Colors.orange),
            );
          }
          break;

        case 'esp32_battery':
          final level = data['level'];
          if (level != null) {
            setState(() => _esp32Battery = (level is int) ? level : (level as double).toInt());
          }
          break;

        case 'pip_unsupported':
          setState(() {
            _pipSupported = false;
            _showPipWindow = false;
            _pipFrameData = null;
          });
          _saveSettings();
          break;
      }
    } catch (e) {
      debugPrint('信令消息处理错误: $e');
    }
  }

  void _toggleAudioMute() {
    setState(() { _isAudioMuted = !_isAudioMuted; });
    _webrtcService.setRemoteAudioMuted(_isAudioMuted);
  }

  void _onPttPressed() {
    _webrtcService.sendDataCommand('stop_audio');
    setState(() { _isPttPressed = true; });
    _webrtcService.startPtt();
  }

  void _onPttReleased() {
    setState(() { _isPttPressed = false; });
    _webrtcService.stopPtt();
  }
  
  Future<void> _handleMusicTap() async {
    if (_isSendingFile) return;
    
    final shouldPick = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('播放音频文件'),
        content: const Text('是否选择音频文件并在发送端播放？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('选择文件')),
        ],
      ),
    );
    
    if (shouldPick == true) {
      try {
        final result = await FilePicker.platform.pickFiles(type: FileType.audio);
        
        if (result != null && result.files.single.path != null) {
          setState(() { _isSendingFile = true; });
          
          final file = File(result.files.single.path!);
          await _webrtcService.sendFile(file);
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('音频文件发送成功，开始播放')),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
        }
      } finally {
        if (mounted) { setState(() { _isSendingFile = false; }); }
      }
    }
  }

  void _toggleFlashlight() {
    _signalingService.sendMessage(jsonEncode({'type': 'flashlight_toggle'}));
  }

  void _switchCamera() {
    _signalingService.sendMessage(jsonEncode({'type': 'camera_switch'}));
  }

  void _changeResolution(VideoResolution resolution) {
    setState(() { _currentResolution = resolution; });
    _signalingService.sendMessage(jsonEncode({
      'type': 'resolution_request',
      'resolution': resolution.name,
    }));
  }

  void _toggleMap() {
    if (_showFullMap) {
      setState(() { _showFullMap = false; _showMiniMap = false; });
    } else if (_showMiniMap) {
      setState(() { _showFullMap = true; });
    } else {
      setState(() { _showMiniMap = true; });
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showSpeedDisplay = prefs.getBool('showSpeedDisplay') ?? true;
      _useKmh = prefs.getBool('useKmh') ?? true;
      _bitrateLevel = prefs.getString('bitrateLevel') ?? 'high';
      _isLandscape = prefs.getBool('isLandscape') ?? true;
      _showPipWindow = prefs.getBool('showPipWindow') ?? false;
      _steeringStrength = prefs.getInt('steeringStrength') ?? 500;
      _throttleStrength = prefs.getInt('throttleStrength') ?? 500;
      _playbackVolume = prefs.getDouble('playbackVolume') ?? 1.0;
      _joystickMode = prefs.getString('joystickMode') ?? 'single';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showSpeedDisplay', _showSpeedDisplay);
    await prefs.setBool('useKmh', _useKmh);
    await prefs.setString('bitrateLevel', _bitrateLevel);
    await prefs.setBool('isLandscape', _isLandscape);
    await prefs.setBool('showPipWindow', _showPipWindow);
    await prefs.setInt('steeringStrength', _steeringStrength);
    await prefs.setInt('throttleStrength', _throttleStrength);
    await prefs.setDouble('playbackVolume', _playbackVolume);
    await prefs.setString('joystickMode', _joystickMode);
  }

  void _sendBitrateConfig() {
    _signalingService.sendMessage(jsonEncode({'type': 'bitrate_config', 'level': _bitrateLevel}));
  }

  void _sendOrientationConfig() {
    _signalingService.sendMessage(jsonEncode({'type': 'orientation_config', 'isLandscape': _isLandscape}));
  }

  void _sendPipConfig() {
    _signalingService.sendMessage(jsonEncode({'type': 'pip_config', 'enabled': _showPipWindow}));
  }

  String _getBitrateLevelName(String level) {
    switch (level) {
      case 'ultra': return '极致 (50Mbps)';
      case 'high': return '高 (25Mbps)';
      case 'medium': return '中 (12Mbps)';
      case 'low': return '低 (5Mbps)';
      default: return '高';
    }
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 16, top: 8, bottom: 8),
                  child: Text('视频码率', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ...['ultra', 'high', 'medium', 'low'].map((level) => RadioListTile<String>(
                  title: Text(_getBitrateLevelName(level)),
                  value: level,
                  groupValue: _bitrateLevel,
                  dense: true,
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => _bitrateLevel = value);
                      setState(() => _bitrateLevel = value);
                      _saveSettings();
                      _sendBitrateConfig();
                    }
                  },
                )),
                const Divider(),
                ListTile(
                  title: const Text('摄像头方向'),
                  trailing: ToggleButtons(
                    isSelected: [_isLandscape, !_isLandscape],
                    onPressed: (index) {
                      setDialogState(() => _isLandscape = index == 0);
                      setState(() => _isLandscape = index == 0);
                      _saveSettings();
                      _sendOrientationConfig();
                    },
                    children: const [
                      Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('横屏')),
                      Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('竖屏')),
                    ],
                  ),
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('显示GPS速度'),
                  value: _showSpeedDisplay,
                  onChanged: (value) {
                    setDialogState(() => _showSpeedDisplay = value);
                    setState(() => _showSpeedDisplay = value);
                    _saveSettings();
                  },
                ),
                if (_showSpeedDisplay)
                  ListTile(
                    title: const Text('速度单位'),
                    trailing: ToggleButtons(
                      isSelected: [_useKmh, !_useKmh],
                      onPressed: (index) {
                        setDialogState(() => _useKmh = index == 0);
                        setState(() => _useKmh = index == 0);
                        _saveSettings();
                      },
                      children: const [
                        Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('km/h')),
                        Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('m/s')),
                      ],
                    ),
                  ),
                const Divider(),
                if (_pipSupported)
                  SwitchListTile(
                    title: Text('开启${_isFrontCamera ? "后置" : "前置"}摄像头小窗'),
                    value: _showPipWindow,
                    onChanged: (value) {
                      setDialogState(() => _showPipWindow = value);
                      setState(() => _showPipWindow = value);
                      _saveSettings();
                      _sendPipConfig();
                    },
                  )
                else
                  ListTile(
                    title: Text('开启${_isFrontCamera ? "后置" : "前置"}摄像头小窗'),
                    subtitle: const Text('发送端设备不支持双摄像头同时使用', style: TextStyle(color: Colors.orange)),
                    trailing: const Icon(Icons.block, color: Colors.grey),
                  ),
                const Divider(),
                ListTile(
                  title: Text('方向力度: $_steeringStrength'),
                  subtitle: Slider(
                    value: _steeringStrength.toDouble(),
                    min: 1, max: 500, divisions: 499,
                    onChanged: (value) {
                      setDialogState(() => _steeringStrength = value.toInt());
                      setState(() => _steeringStrength = value.toInt());
                    },
                    onChangeEnd: (_) => _saveSettings(),
                  ),
                ),
                ListTile(
                  title: Text('油门力度: $_throttleStrength'),
                  subtitle: Slider(
                    value: _throttleStrength.toDouble(),
                    min: 1, max: 500, divisions: 499,
                    onChanged: (value) {
                      setDialogState(() => _throttleStrength = value.toInt());
                      setState(() => _throttleStrength = value.toInt());
                    },
                    onChangeEnd: (_) => _saveSettings(),
                  ),
                ),
                ListTile(
                  title: Text('放音音量: ${(_playbackVolume * 100).toInt()}%'),
                  subtitle: Slider(
                    value: _playbackVolume,
                    min: 0, max: 1, divisions: 100,
                    onChanged: (value) {
                      setDialogState(() => _playbackVolume = value);
                      setState(() => _playbackVolume = value);
                      _webrtcService.setRemoteAudioVolume(value);
                    },
                    onChangeEnd: (_) => _saveSettings(),
                  ),
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.only(left: 16, top: 8, bottom: 8),
                  child: Text('摇杆模式', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                RadioListTile<String>(
                  title: const Text('单摇杆'), value: 'single', groupValue: _joystickMode, dense: true,
                  onChanged: (v) { setDialogState(() => _joystickMode = v!); setState(() => _joystickMode = v!); _saveSettings(); },
                ),
                RadioListTile<String>(
                  title: const Text('双摇杆（左右，前后）'), value: 'dual_lr_fb', groupValue: _joystickMode, dense: true,
                  onChanged: (v) { setDialogState(() => _joystickMode = v!); setState(() => _joystickMode = v!); _saveSettings(); },
                ),
                RadioListTile<String>(
                  title: const Text('双摇杆（前后，左右）'), value: 'dual_fb_lr', groupValue: _joystickMode, dense: true,
                  onChanged: (v) { setDialogState(() => _joystickMode = v!); setState(() => _joystickMode = v!); _saveSettings(); },
                ),
                const Divider(),
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('© 2026-present NORMAL-EX.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
        ),
      ),
    );
  }

  String _getSpeedText() {
    if (_useKmh) {
      return '${(_gpsSpeed * 3.6).toStringAsFixed(1)} km/h';
    } else {
      return '${_gpsSpeed.toStringAsFixed(1)} m/s';
    }
  }

  IconData _getBatteryIcon() {
    if (_senderBatteryLevel < 0) return Icons.battery_unknown;
    if (_senderBatteryLevel <= 10) return Icons.battery_alert;
    if (_senderBatteryLevel <= 20) return Icons.battery_1_bar;
    if (_senderBatteryLevel <= 35) return Icons.battery_2_bar;
    if (_senderBatteryLevel <= 50) return Icons.battery_3_bar;
    if (_senderBatteryLevel <= 65) return Icons.battery_4_bar;
    if (_senderBatteryLevel <= 80) return Icons.battery_5_bar;
    if (_senderBatteryLevel <= 95) return Icons.battery_6_bar;
    return Icons.battery_full;
  }

  Color _getBatteryColor() {
    if (_senderBatteryLevel < 0) return Colors.grey;
    if (_senderBatteryLevel <= 20) return Colors.red;
    if (_senderBatteryLevel <= 50) return Colors.orange;
    return Colors.green;
  }

  // 摇杆控制
  Offset _joystickPos = Offset.zero;
  Offset _joystickPos2 = Offset.zero;

  Widget _buildJoystick(Offset pos, void Function(Offset) onUpdate, void Function() onEnd) {
    const double size = 150;
    const double knobSize = 60;
    const double maxOff = (size - knobSize) / 2;
    return GestureDetector(
      onPanUpdate: (details) {
        final dx = (details.localPosition.dx - size / 2).clamp(-maxOff, maxOff);
        final dy = (details.localPosition.dy - size / 2).clamp(-maxOff, maxOff);
        onUpdate(Offset(dx, dy));
        _sendRcCommand();
      },
      onPanEnd: (_) {
        onEnd();
        _sendRcCommand();
      },
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.3),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white30, width: 2),
        ),
        child: Center(
          child: Transform.translate(
            offset: pos,
            child: Container(
              width: knobSize, height: knobSize,
              decoration: const BoxDecoration(color: Colors.white70, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLeftJoystick() {
    return _buildJoystick(_joystickPos, (o) => setState(() => _joystickPos = o), () => setState(() => _joystickPos = Offset.zero));
  }

  Widget _buildRightJoystick() {
    return _buildJoystick(_joystickPos2, (o) => setState(() => _joystickPos2 = o), () => setState(() => _joystickPos2 = Offset.zero));
  }

  void _sendRcCommand() {
    const double maxOffset = 45;
    int steering, throttle;
    if (_joystickMode == 'single') {
      steering = 1500 + (_joystickPos.dx / maxOffset * _steeringStrength).toInt();
      throttle = 1500 - (_joystickPos.dy / maxOffset * _throttleStrength).toInt();
    } else if (_joystickMode == 'dual_lr_fb') {
      steering = 1500 + (_joystickPos.dx / maxOffset * _steeringStrength).toInt();
      throttle = 1500 - (_joystickPos2.dy / maxOffset * _throttleStrength).toInt();
    } else {
      throttle = 1500 - (_joystickPos.dy / maxOffset * _throttleStrength).toInt();
      steering = 1500 + (_joystickPos2.dx / maxOffset * _steeringStrength).toInt();
    }
    _webrtcService.sendDataCommand('RC:S:$steering,T:$throttle');
  }

  Future<bool> _showDisconnectConfirmation() async {
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('确定要断开视频连接吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('确定')),
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('确定断开')),
        ],
      ),
    );
    return secondConfirm == true;
  }

  Future<void> _handleBackPress() async {
    if (_showFullMap) {
      setState(() { _showFullMap = false; _showMiniMap = false; });
      return;
    }

    if (_isConnected) {
      final shouldDisconnect = await _showDisconnectConfirmation();
      if (shouldDisconnect) {
        _exitFullscreen();
        if (mounted) Navigator.pop(context);
      }
    } else {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    NativeWakelock.disable();

    if (_isConnected) {
      _signalingService.sendMessage(jsonEncode({'type': 'disconnect'}));
    }

    _latencyTimer?.cancel();
    _exitFullscreen();
    _scannerController.dispose();
    _webrtcService.dispose();
    _signalingService.close();
    super.dispose();
  }

  Widget _buildMap({required bool fullscreen}) {
    if (_senderLocation == null) {
      return Container(
        color: Colors.grey.shade800,
        child: const Center(child: Text('等待GPS数据...', style: TextStyle(color: Colors.white70))),
      );
    }
    
    return FlutterMap(
      mapController: fullscreen ? _mapController : null,
      options: MapOptions(
        initialCenter: _senderLocation!,
        initialZoom: fullscreen ? 16 : 14,
        interactionOptions: fullscreen 
            ? const InteractionOptions() 
            : const InteractionOptions(flags: InteractiveFlag.none),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.simple_car',
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: _senderLocation!,
              child: Icon(Icons.location_pin, color: Colors.red, size: fullscreen ? 40 : 24),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 全屏大地图
    if (_showFullMap) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async { if (!didPop) await _handleBackPress(); },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              _buildMap(fullscreen: true),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8, left: 8,
                child: Container(
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () { setState(() { _showFullMap = false; _showMiniMap = false; }); },
                  ),
                ),
              ),
              if (_senderLocation != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8, right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(12)),
                    child: Text(
                      '${_senderLocation!.latitude.toStringAsFixed(6)}, ${_senderLocation!.longitude.toStringAsFixed(6)}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    
    // 连接成功后显示全屏视频
    if (_isConnected) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async { if (!didPop) await _handleBackPress(); },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child: RTCVideoView(_webrtcService.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
              ),
              if (_showPipWindow)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 60, right: 8,
                  child: GestureDetector(
                    onTap: _switchCamera,
                    child: Container(
                      width: 120, height: 90,
                      decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(8)),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _pipFrameData != null
                            ? Image.memory(_pipFrameData!, fit: BoxFit.cover, gaplessPlayback: true)
                            : const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
                      ),
                    ),
                  ),
                ),
              // 左上角：返回 + 延迟
              Positioned(
                top: MediaQuery.of(context).padding.top + 8, left: 8,
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                      child: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: _handleBackPress),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.network_ping, color: _latencyMs < 50 ? Colors.green : _latencyMs < 100 ? Colors.yellow : Colors.red, size: 16),
                          const SizedBox(width: 4),
                          Text('${_latencyMs}ms', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 右上角：电量 + 设置 + 分辨率
              Positioned(
                top: MediaQuery.of(context).padding.top + 8, right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.directions_car, color: Colors.white70, size: 16),
                          const SizedBox(width: 4),
                          if (_esp32Connected && _esp32Battery >= 0) ...[
                            Icon(_esp32Battery <= 20 ? Icons.battery_alert : Icons.battery_std, color: _esp32Battery <= 20 ? Colors.red : Colors.green, size: 20),
                            Text('$_esp32Battery%', style: TextStyle(color: _esp32Battery <= 20 ? Colors.red : Colors.green, fontSize: 12, fontWeight: FontWeight.bold)),
                          ] else
                            const Stack(alignment: Alignment.center, children: [
                              Icon(Icons.battery_std, color: Colors.grey, size: 20),
                              Text('×', style: TextStyle(color: Colors.red, fontSize: 14, fontWeight: FontWeight.bold)),
                            ]),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_senderBatteryLevel >= 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(16)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_getBatteryIcon(), color: _getBatteryColor(), size: 20),
                            const SizedBox(width: 2),
                            Text('$_senderBatteryLevel%', style: TextStyle(color: _getBatteryColor(), fontSize: 12, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                      child: IconButton(icon: const Icon(Icons.settings, color: Colors.white), onPressed: _showSettingsDialog),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                      child: PopupMenuButton<VideoResolution>(
                        icon: const Icon(Icons.high_quality, color: Colors.white),
                        onSelected: _changeResolution,
                        itemBuilder: (context) {
                          return _availableResolutions.map((res) {
                            final isSelected = res.name == _currentResolution.name;
                            return PopupMenuItem<VideoResolution>(
                              value: res,
                              child: Row(children: [
                                if (isSelected) const Icon(Icons.check, color: Colors.green, size: 18) else const SizedBox(width: 18),
                                const SizedBox(width: 8),
                                Text(res.name),
                                Text(' (${res.width}x${res.height})', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                              ]),
                            );
                          }).toList();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // 左下角：地图
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 24, left: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_showMiniMap && _senderLocation != null)
                      GestureDetector(
                        onTap: _toggleMap,
                        child: Container(
                          width: 150, height: 100,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white, width: 2)),
                          clipBehavior: Clip.antiAlias,
                          child: _buildMap(fullscreen: false),
                        ),
                      ),
                    Container(
                      decoration: BoxDecoration(
                        color: _senderLocation != null ? (_showMiniMap ? Colors.green.withOpacity(0.7) : Colors.black.withOpacity(0.5)) : Colors.black.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.map, color: _senderLocation != null ? Colors.white : Colors.orange),
                        onPressed: () {
                          if (_senderLocation != null) {
                            _toggleMap();
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('等待发送端GPS定位...'), duration: Duration(seconds: 2)),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // 左下角：摇杆（左）
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 100, left: 16,
                child: _buildLeftJoystick(),
              ),
              // 右下角：摇杆（右）
              if (_joystickMode != 'single')
                Positioned(
                  bottom: MediaQuery.of(context).padding.bottom + 100, right: 16,
                  child: _buildRightJoystick(),
                ),
              // 右下角：控制按钮
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 24, right: 16,
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                      child: IconButton(icon: const Icon(Icons.cameraswitch, color: Colors.white), onPressed: _switchCamera),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(color: _isFlashlightOn ? Colors.yellow.withOpacity(0.7) : Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                      child: IconButton(
                        icon: Icon(_isFlashlightOn ? Icons.flashlight_on : Icons.flashlight_off, color: Colors.white),
                        onPressed: _toggleFlashlight,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                      child: IconButton(
                        icon: Icon(_isAudioMuted ? Icons.volume_off : Icons.volume_up, color: _isAudioMuted ? Colors.red : Colors.white),
                        onPressed: _toggleAudioMute,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _handleMusicTap,
                      child: Container(
                        decoration: BoxDecoration(color: _isSendingFile ? Colors.blue.withOpacity(0.7) : Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: _isSendingFile
                              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                              : const Icon(Icons.music_note, color: Colors.white70),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPressStart: (_) => _onPttPressed(),
                      onLongPressEnd: (_) => _onPttReleased(),
                      child: Container(
                        decoration: BoxDecoration(color: _isPttPressed ? Colors.red.withOpacity(0.7) : Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(24)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Icon(Icons.mic, color: _isPttPressed ? Colors.white : Colors.white70),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 底部中间：GPS速度
              if (_showSpeedDisplay && _senderLocation != null)
                Positioned(
                  bottom: MediaQuery.of(context).padding.bottom + 24, left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.speed, color: Colors.white, size: 24),
                          const SizedBox(width: 8),
                          Text(_getSpeedText(), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
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
    
    // 扫码界面
    return Scaffold(
      appBar: AppBar(title: const Text('接收端'), backgroundColor: Colors.green.shade800),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.green.shade900, Colors.black]),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                color: _isConnecting ? Colors.orange.shade700 : Colors.grey.shade700,
                child: Row(
                  children: [
                    Icon(_isConnecting ? Icons.pending : Icons.qr_code_scanner, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_statusMessage, style: const TextStyle(color: Colors.white))),
                  ],
                ),
              ),
              Expanded(child: _isScanning ? _buildScanner() : _buildConnecting()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          controller: _scannerController,
          onDetect: (capture) {
            for (final barcode in capture.barcodes) {
              if (barcode.rawValue != null) { _handleQRCode(barcode.rawValue!); break; }
            }
          },
        ),
        Center(
          child: Container(
            width: 280, height: 280,
            decoration: BoxDecoration(border: Border.all(color: Colors.green, width: 3), borderRadius: BorderRadius.circular(16)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: const Text('将二维码放入框内', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 32, right: 32,
          child: FloatingActionButton(
            backgroundColor: Colors.green.shade700,
            onPressed: () => _scannerController.toggleTorch(),
            child: ValueListenableBuilder(
              valueListenable: _scannerController,
              builder: (context, state, child) {
                return Icon(state.torchState == TorchState.on ? Icons.flash_on : Icons.flash_off);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConnecting() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 24),
          Text(_statusMessage, style: const TextStyle(color: Colors.white70, fontSize: 16), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
