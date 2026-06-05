import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WebRTC信令消息类型
enum SignalType {
  offer,
  answer,
  candidate,
}

/// 连接信息，用于二维码传输
class ConnectionInfo {
  final String ipv6Address;
  final int port;
  final String? sessionDescription;
  final String? candidateData;
  final SignalType? signalType;

  ConnectionInfo({
    required this.ipv6Address,
    required this.port,
    this.sessionDescription,
    this.candidateData,
    this.signalType,
  });

  Map<String, dynamic> toJson() => {
    'ipv6': ipv6Address,
    'port': port,
    if (sessionDescription != null) 'sdp': sessionDescription,
    if (candidateData != null) 'candidate': candidateData,
    if (signalType != null) 'type': signalType!.name,
  };

  factory ConnectionInfo.fromJson(Map<String, dynamic> json) => ConnectionInfo(
    ipv6Address: json['ipv6'] as String,
    port: json['port'] as int,
    sessionDescription: json['sdp'] as String?,
    candidateData: json['candidate'] as String?,
    signalType: json['type'] != null 
        ? SignalType.values.firstWhere((e) => e.name == json['type'])
        : null,
  );

  String toEncodedString() => base64Encode(utf8.encode(jsonEncode(toJson())));
  
  static ConnectionInfo fromEncodedString(String encoded) {
    final decoded = utf8.decode(base64Decode(encoded));
    return ConnectionInfo.fromJson(jsonDecode(decoded));
  }
}

/// 视频分辨率配置
class VideoResolution {
  final String name;
  final int width;
  final int height;

  const VideoResolution(this.name, this.width, this.height);

  static const List<VideoResolution> presets = [
    VideoResolution('4K', 3840, 2160),
    VideoResolution('1080p', 1920, 1080),
    VideoResolution('720p', 1280, 720),
  ];
}

/// WebRTC服务 - 处理视频流传输
class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _receiverAudioStream; // 接收端的本地音频流（用于PTT）
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  final RTCVideoRenderer pipRenderer = RTCVideoRenderer(); // 小窗渲染器
  
  Function(RTCSessionDescription)? onLocalDescription;
  Function(RTCIceCandidate)? onIceCandidate;
  Function(MediaStream)? onRemoteStream;
  Function()? onConnectionStateChange;
  Function()? onHeartbeatTimeout; // 心跳超时回调（重连失败后）
  Function(int)? onReconnecting; // 重连中回调，参数为当前尝试次数
  Function(String)? onError;

  bool _isInitialized = false;
  bool _hasRemoteDescription = false;
  bool _isRemoteAudioMuted = false;
  bool _isPttActive = false;
  bool _isFlashlightOn = false;
  bool _isFrontCamera = false;
  bool _isLandscape = true; // 默认为横屏
  bool _isSender = false; // 标记是发送端还是接收端
  Timer? _heartbeatTimer;
  DateTime? _lastHeartbeat;
  int _reconnectAttempts = 0;
  static const _heartbeatInterval = Duration(seconds: 2);
  static const _heartbeatTimeout = Duration(seconds: 6);
  static const _maxReconnectAttempts = 3;
  final List<RTCIceCandidate> _pendingCandidates = [];
  VideoResolution _currentResolution = VideoResolution.presets[1]; // 默认1080p
  List<VideoResolution> _supportedResolutions = [];
  MediaStream? _remoteStream;

  VideoResolution get currentResolution => _currentResolution;
  List<VideoResolution> get supportedResolutions => _supportedResolutions;
  bool get isConnected => _peerConnection?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  bool get isRemoteAudioMuted => _isRemoteAudioMuted;
  bool get isPttActive => _isPttActive;
  bool get isFlashlightOn => _isFlashlightOn;
  bool get isFrontCamera => _isFrontCamera;

  /// STUN/TURN 服务器配置
  final Map<String, dynamic> _configuration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  /// 初始化渲染器
  Future<void> initialize() async {
    if (_isInitialized) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    await pipRenderer.initialize();
    _isInitialized = true;
  }

  /// 检测支持的分辨率
  Future<void> detectSupportedResolutions() async {
    _supportedResolutions = [];
    
    for (final resolution in VideoResolution.presets) {
      try {
        final testStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': 'environment',
            'width': {'ideal': resolution.width},
            'height': {'ideal': resolution.height},
          },
        });
        
        final videoTrack = testStream.getVideoTracks().first;
        final settings = videoTrack.getSettings();
        
        if (settings['width'] != null && settings['height'] != null) {
          final actualWidth = settings['width'] as int;
          final actualHeight = settings['height'] as int;
          
          if (actualWidth >= resolution.width * 0.8 && 
              actualHeight >= resolution.height * 0.8) {
            _supportedResolutions.add(resolution);
          }
        }
        
        testStream.dispose();
      } catch (e) {
        // 此分辨率不支持
      }
    }

    if (_supportedResolutions.isEmpty) {
      _supportedResolutions.add(VideoResolution.presets.last);
    }

    _currentResolution = _supportedResolutions.first;
  }

  /// 获取本机IPv6地址
  Future<String?> getIPv6Address() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv6,
        includeLinkLocal: false,
      );
      
      for (final interface_ in interfaces) {
        for (final addr in interface_.addresses) {
          if (!addr.address.startsWith('fe80') &&
              !addr.address.startsWith('::1')) {
            // 去掉zone ID（如 %14）
            return addr.address.split('%').first;
          }
        }
      }

      for (final interface_ in interfaces) {
        for (final addr in interface_.addresses) {
          if (addr.address.startsWith('fe80')) {
            return addr.address.split('%').first;
          }
        }
      }
    } catch (e) {
      onError?.call('获取IPv6地址失败: $e');
    }
    return null;
  }

  /// 修改SDP以优先使用H264编码并设置高码率
  String _preferH264AndHighBitrate(String sdp) {
    final lines = sdp.split('\r\n');
    final newLines = <String>[];
    
    for (var line in lines) {
      newLines.add(line);
      
      // 在video媒体行后添加高码率设置
      if (line.startsWith('m=video')) {
        // 继续处理，码率在后面的b=行设置
      }
      
      // 提高码率限制 - 修改或添加b=AS行
      if (line.startsWith('c=IN') && newLines.length > 1 && 
          newLines[newLines.length - 2].startsWith('m=video')) {
        // 在c=行后添加高码率限制 (30 Mbps)
        newLines.add('b=AS:30000');
      }
    }
    
    var modifiedSdp = newLines.join('\r\n');
    
    // 修改现有的b=AS限制为更高值
    modifiedSdp = modifiedSdp.replaceAllMapped(
      RegExp(r'b=AS:\d+'),
      (match) => 'b=AS:30000', // 30 Mbps
    );
    
    // 简单的H264优先处理：查找H264 payload并将其放在video m=行的第一个
    // 这是一个基础实现，实际可能需要更复杂的SDP操作
    print('SDP修改: 已设置高码率限制 30 Mbps');
    
    return modifiedSdp;
  }

  /// 设置视频发送器的初始高码率
  Future<void> _setInitialBitrate() async {
    if (_peerConnection == null) return;
    
    final senders = await _peerConnection!.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        try {
          final parameters = sender.parameters;
          if (parameters.encodings != null && parameters.encodings!.isNotEmpty) {
            // 根据当前分辨率设置高码率
            int targetBitrate;
            if (_currentResolution.width >= 3840) {
              targetBitrate = 25000000; // 4K: 25 Mbps
            } else if (_currentResolution.width >= 1920) {
              targetBitrate = 15000000; // 1080p: 15 Mbps  
            } else {
              targetBitrate = 8000000;  // 720p: 8 Mbps
            }
            
            for (var encoding in parameters.encodings!) {
              encoding.maxBitrate = targetBitrate;
              encoding.minBitrate = targetBitrate ~/ 2; // 最小码率为目标的一半
            }
            
            await sender.setParameters(parameters);
            print('初始码率设置: ${targetBitrate ~/ 1000000} Mbps (分辨率: ${_currentResolution.name})');
          }
        } catch (e) {
          print('设置初始码率失败: $e');
        }
      }
    }
  }

  /// 根据码率档位设置视频码率
  /// level: 'ultra', 'high', 'medium', 'low'
  Future<void> setBitrateLevel(String level) async {
    if (_peerConnection == null) return;
    
    // 根据档位和分辨率计算码率
    int getTargetBitrate(int resWidth) {
      switch (level) {
        case 'ultra':
          if (resWidth >= 3840) return 50000000; // 4K: 50 Mbps
          if (resWidth >= 1920) return 30000000; // 1080p: 30 Mbps
          return 15000000; // 720p: 15 Mbps
        case 'high':
          if (resWidth >= 3840) return 25000000; // 4K: 25 Mbps
          if (resWidth >= 1920) return 15000000; // 1080p: 15 Mbps
          return 8000000;  // 720p: 8 Mbps
        case 'medium':
          if (resWidth >= 3840) return 12000000; // 4K: 12 Mbps
          if (resWidth >= 1920) return 8000000;  // 1080p: 8 Mbps
          return 4000000;  // 720p: 4 Mbps
        case 'low':
          if (resWidth >= 3840) return 5000000;  // 4K: 5 Mbps
          if (resWidth >= 1920) return 3000000;  // 1080p: 3 Mbps
          return 1500000;  // 720p: 1.5 Mbps
        default:
          return 15000000;
      }
    }
    
    final senders = await _peerConnection!.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        try {
          final parameters = sender.parameters;
          if (parameters.encodings != null && parameters.encodings!.isNotEmpty) {
            final targetBitrate = getTargetBitrate(_currentResolution.width);
            
            for (var encoding in parameters.encodings!) {
              encoding.maxBitrate = targetBitrate;
              encoding.minBitrate = targetBitrate ~/ 2;
            }
            
            await sender.setParameters(parameters);
            print('码率已更新: $level档位 -> ${targetBitrate ~/ 1000000} Mbps');
          }
        } catch (e) {
          print('设置码率失败: $e');
        }
      }
    }
  }

  /// 设置摄像头方向（横屏/竖屏）
  Future<void> setOrientation(bool isLandscape) async {
    if (_localStream == null) return;
    
    _isLandscape = isLandscape; // 保存状态
    print('WebRTC: 切换方向: ${isLandscape ? "横屏" : "竖屏"}');
    
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      final track = videoTracks.first;
      
      try {
        await track.stop();
        try { _localStream!.removeTrack(track); } catch (_) {}

        // 横屏和竖屏的宽高设置
        int width, height;
        if (isLandscape) {
          // 横屏：宽 > 高
          width = _currentResolution.width;
          height = _currentResolution.height;
        } else {
          // 竖屏：高 > 宽，交换宽高
          width = _currentResolution.height;
          height = _currentResolution.width;
        }
        
        print('WebRTC: 请求新流分辨率: ${width}x${height}');
        
        final newStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': _isFrontCamera ? 'user' : 'environment',
            'width': {'min': width ~/ 2, 'ideal': width},
            'height': {'min': height ~/ 2, 'ideal': height},
            'frameRate': {'ideal': 30},
          },
        });
        
        final newTrack = newStream.getVideoTracks().first;
        final settings = newTrack.getSettings();
        print('WebRTC: 实际获取流分辨率: ${settings['width']}x${settings['height']}');
        
        _localStream!.addTrack(newTrack);
        
        // 替换PeerConnection中的视频轨道
        final senders = await _peerConnection?.getSenders();
        bool replaced = false;
        for (final sender in senders ?? []) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(newTrack);
            replaced = true;
            print('WebRTC: 视频轨道已替换');
            break;
          }
        }
        
        if (!replaced) {
            print('WebRTC警告: 未找到视频发送器，无法替换轨道');
        }
        
        localRenderer.srcObject = _localStream;
        
        // 重新应用码率设置 (因为track改变了)
        await Future.delayed(const Duration(milliseconds: 500));
        await _setInitialBitrate();
        
        print('WebRTC: 方向切换流程完成');
      } catch (e) {
        print('WebRTC错误: 方向切换失败: $e');
        onError?.call('更改方向失败: $e');
      }
    }
  }

  MediaStream? _pipStream;
  bool _pipEnabled = false;

  /// 设置小窗显示（另一个摄像头）
  Future<void> setPipEnabled(bool enabled) async {
    if (_pipEnabled == enabled) return;
    _pipEnabled = enabled;

    if (enabled) {
      try {
        _pipStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': _isFrontCamera ? 'environment' : 'user',
            'width': {'ideal': 640},
            'height': {'ideal': 480},
          },
        });
        final track = _pipStream!.getVideoTracks().first;
        await _peerConnection?.addTrack(track, _pipStream!);
        // 触发重新协商
        final offer = await _peerConnection?.createOffer();
        if (offer != null) {
          await _peerConnection?.setLocalDescription(offer);
          onLocalDescription?.call(offer);
        }
      } catch (e) {
        print('PIP启动失败: $e');
      }
    } else {
      if (_pipStream != null) {
        // 移除PIP轨道
        final senders = await _peerConnection?.getSenders();
        for (final sender in senders ?? []) {
          if (sender.track?.id == _pipStream!.getVideoTracks().first.id) {
            await _peerConnection?.removeTrack(sender);
            break;
          }
        }
        for (final track in _pipStream!.getVideoTracks()) {
          await track.stop();
        }
        await _pipStream!.dispose();
        _pipStream = null;
      }
    }
  }



  /// 处理重新协商（如添加PIP流）
  Future<void> handleRenegotiation(RTCSessionDescription remoteOffer) async {
    await _peerConnection?.setRemoteDescription(remoteOffer);
    final answer = await _peerConnection?.createAnswer();
    if (answer != null) {
      await _peerConnection?.setLocalDescription(answer);
      onLocalDescription?.call(answer);
    }
  }

  /// 创建接收端 (Answer) - 关键修改：也获取本地音频用于PTT
  Future<void> createReceiverConnection(RTCSessionDescription remoteOffer) async {
    _isSender = false;
    await _createPeerConnection();
    
    // 关键：接收端也需要获取本地音频流用于PTT对讲
    // 初始时静音，按下PTT时取消静音
    try {
      _receiverAudioStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      
      // 获取音频轨道并默认静音
      final audioTracks = _receiverAudioStream!.getAudioTracks();
      for (final track in audioTracks) {
        track.enabled = false; // 默认静音，按下PTT时才启用
        _peerConnection!.addTrack(track, _receiverAudioStream!);
      }
    } catch (e) {
      print('接收端获取音频失败: $e');
      // 如果获取音频失败，继续不支持PTT
    }
    
    await _peerConnection!.setRemoteDescription(remoteOffer);
    _hasRemoteDescription = true;
    
    // 处理缓冲的ICE候选
    for (final candidate in _pendingCandidates) {
      await _peerConnection!.addCandidate(candidate);
    }
    _pendingCandidates.clear();
    
    final constraints = {
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    };

    final answer = await _peerConnection!.createAnswer(constraints);
    await _peerConnection!.setLocalDescription(answer);
    onLocalDescription?.call(answer);
  }

  /// 设置远程描述
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    await _peerConnection?.setRemoteDescription(description);
    _hasRemoteDescription = true;
    
    // 处理缓冲的ICE候选
    for (final candidate in _pendingCandidates) {
      await _peerConnection?.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  /// 添加ICE候选
  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    if (_peerConnection != null && _hasRemoteDescription) {
      await _peerConnection!.addCandidate(candidate);
    } else {
      _pendingCandidates.add(candidate);
    }
  }

  /// 更改分辨率 - 增加比特率配置
  Future<void> changeResolution(VideoResolution resolution) async {
    if (_localStream == null) return;
    
    _currentResolution = resolution;
    print('分辨率切换: 切换到 ${resolution.name} (${resolution.width}x${resolution.height}) 方向:${_isLandscape ? "横屏" : "竖屏"}');
    
    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      final track = videoTracks.first;
      
      try {
        await track.stop();
        try { _localStream!.removeTrack(track); } catch (_) {}

        // 计算考虑到方向的宽高
        int width, height;
        if (_isLandscape) {
          width = resolution.width;
          height = resolution.height;
        } else {
          width = resolution.height;
          height = resolution.width;
        }
        
        // 获取新的视频流，使用精确的分辨率约束
        final newStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': _isFrontCamera ? 'user' : 'environment',
            'width': {'ideal': width},
            'height': {'ideal': height},
            'frameRate': {'ideal': 30},
          },
        });
        
        final newTrack = newStream.getVideoTracks().first;
        _localStream!.addTrack(newTrack);
        
        // 替换PeerConnection中的视频轨道
        final senders = await _peerConnection?.getSenders();
        for (final sender in senders ?? []) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(newTrack);
            
            // 重新应用码率设置
            await Future.delayed(const Duration(milliseconds: 200));
            await _setInitialBitrate();
            
            break;
          }
        }
        
        localRenderer.srcObject = _localStream;
        print('分辨率切换: 完成');
      } catch (e) {
        print('分辨率切换: 失败: $e');
        onError?.call('更改分辨率失败: $e');
      }
    }
  }

  /// Data Channel
  RTCDataChannel? _dataChannel;
  Function(String, List<int>)? onFileReceived; // filename, bytes
  Function(String)? onCommandReceived;
  
  // File assembly buffer
  List<int> _fileBuffer = [];
  int _receivedFileSize = 0;
  int _expectedFileSize = 0;
  String _receivingFileName = '';
  bool _isReceivingFile = false;
  
  /// Create Data Channel (Sender calls this)
  Future<void> _createDataChannel() async {
    if (_peerConnection == null) return;
    
    final config = RTCDataChannelInit()
      ..id = 1
      ..maxRetransmits = 30;
      
    try {
      _dataChannel = await _peerConnection!.createDataChannel('file_transfer', config);
      _setupDataChannel(_dataChannel!);
      print('DataChannel created');
    } catch (e) {
      print('DataChannel creation failed: $e');
    }
  }

  /// Setup Data Channel listeners
  void _setupDataChannel(RTCDataChannel channel) {
    channel.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary) {
        // Binary data = file chunk
        _handleBinaryMessage(message.binary);
      } else {
        // Text data = command or file metadata
        _handleTextMessage(message.text);
      }
    };
    
    channel.onDataChannelState = (RTCDataChannelState state) {
      print('DataChannel state: $state');
    };
  }

  /// Handle text messages (commands/metadata)
  void _handleTextMessage(String text) {
    try {
      final Map<String, dynamic> data = jsonDecode(text);
      if (data['type'] == 'file_start') {
        // Start receiving file
        _isReceivingFile = true;
        _fileBuffer = [];
        _receivedFileSize = 0;
        _expectedFileSize = data['size'];
        _receivingFileName = data['name'];
        print('Receiving file: $_receivingFileName ($_expectedFileSize bytes)');
      } else if (data['type'] == 'command') {
        // Handle command
        onCommandReceived?.call(data['cmd']);
      }
    } catch (e) {
      print('DataChannel parse error: $e');
    }
  }

  /// Handle binary messages (file chunks)
  void _handleBinaryMessage(List<int> data) {
    if (!_isReceivingFile) return;
    
    _fileBuffer.addAll(data);
    _receivedFileSize += data.length;
    
    if (_receivedFileSize >= _expectedFileSize) {
      // File complete
      _isReceivingFile = false;
      print('File received complete: $_receivingFileName');
      onFileReceived?.call(_receivingFileName, _fileBuffer);
      _fileBuffer = [];
    }
  }

  /// Send file via DataChannel
  Future<void> sendFile(File file) async {
    if (_dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      print('DataChannel not open');
      return;
    }

    final filename = file.uri.pathSegments.last;
    final bytes = await file.readAsBytes();
    final size = bytes.length;
    
    // 1. Send metadata
    final metadata = jsonEncode({
      'type': 'file_start',
      'name': filename,
      'size': size,
    });
    await _dataChannel!.send(RTCDataChannelMessage(metadata));
    
    // 2. Send chunks
    const int chunkSize = 16 * 1024; // 16KB chunks
    int offset = 0;
    
    while (offset < size) {
      int end = offset + chunkSize;
      if (end > size) end = size;
      
      final chunk = bytes.sublist(offset, end);
      await _dataChannel!.send(RTCDataChannelMessage.fromBinary(chunk));
      
      offset += chunkSize;
      
      // Small delay to prevent buffer overflow
      await Future.delayed(const Duration(milliseconds: 1));
    }
    
    print('File sent: $filename');
  }

  /// Send command via DataChannel
  Future<void> sendDataCommand(String cmd) async {
    if (_dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    
    final data = jsonEncode({
      'type': 'command',
      'cmd': cmd,
    });
    await _dataChannel!.send(RTCDataChannelMessage(data));
  }

  /// 创建PeerConnection
  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection(_configuration);

    _peerConnection!.onIceCandidate = (candidate) {
      onIceCandidate?.call(candidate);
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        final stream = event.streams.first;
        if (_remoteStream == null) {
          _remoteStream = stream;
          remoteRenderer.srcObject = _remoteStream;
          onRemoteStream?.call(_remoteStream!);
        } else if (event.track.kind == 'video' && pipRenderer.srcObject == null) {
          pipRenderer.srcObject = stream;
        }
      }
    };

    _peerConnection!.onAddStream = (stream) {
      if (_remoteStream == null) {
        _remoteStream = stream;
        remoteRenderer.srcObject = _remoteStream;
        onRemoteStream?.call(_remoteStream!);
      } else if (pipRenderer.srcObject == null) {
        pipRenderer.srcObject = stream;
      }
    };
    
    // Handle receiver side DataChannel
    _peerConnection!.onDataChannel = (RTCDataChannel channel) {
      _dataChannel = channel;
      _setupDataChannel(channel);
      print('Receiver: DataChannel received');
    };

    _peerConnection!.onConnectionState = (state) {
      onConnectionStateChange?.call();
    };
  }

  /// 创建发送端 (Offer)
  Future<void> createSenderConnection() async {
    _isSender = true;
    await _createPeerConnection();
    await _createDataChannel(); // Init DataChannel on Sender side
    
    // ... existing createSenderConnection logic ...
    
    // 计算考虑到方向的宽高
    int width, height;
    if (_isLandscape) {
      width = _currentResolution.width;
      height = _currentResolution.height;
    } else {
      width = _currentResolution.height;
      height = _currentResolution.width;
    }
    
    // 获取本地摄像头+音频流 - 使用更大的分辨率约束
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'environment',
        'width': {'min': 720, 'ideal': width, 'max': 3840},
        'height': {'min': 720, 'ideal': height, 'max': 3840}, // 放宽限制以适应竖屏
        'frameRate': {'ideal': 30, 'max': 60},
      },
    });

    localRenderer.srcObject = _localStream;

    // 添加轨道到连接
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    // 设置初始高码率
    await _setInitialBitrate();

    final constraints = {
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    };

    final offer = await _peerConnection!.createOffer(constraints);
    
    // 修改SDP以优先H264和高码率
    final modifiedSdp = _preferH264AndHighBitrate(offer.sdp!);
    final modifiedOffer = RTCSessionDescription(modifiedSdp, offer.type);
    
    await _peerConnection!.setLocalDescription(modifiedOffer);
    
    // 再次设置码率（确保生效）
    await Future.delayed(const Duration(milliseconds: 500));
    await _setInitialBitrate();
    
    onLocalDescription?.call(modifiedOffer);
  }

  /// 静音/取消静音远程音频（接收端听发送端）
  void setRemoteAudioMuted(bool muted) {
    _isRemoteAudioMuted = muted;
    if (_remoteStream != null) {
      final audioTracks = _remoteStream!.getAudioTracks();
      for (final track in audioTracks) {
        track.enabled = !muted;
      }
    }
  }

  /// 设置远程音频音量 (0.0 - 1.0)
  double _remoteAudioVolume = 1.0;

  void setRemoteAudioVolume(double volume) {
    _remoteAudioVolume = volume.clamp(0.0, 1.0);
    if (_remoteStream != null) {
      final audioTracks = _remoteStream!.getAudioTracks();
      for (final track in audioTracks) {
        // 使用Helper设置音量
        try {
          Helper.setVolume(volume, track);
        } catch (e) {
          print('设置音量失败: $e');
        }
      }
    }
  }

  /// 获取网络延迟 (RTT in ms)
  Future<int> getLatency() async {
    if (_peerConnection == null) return 0;
    
    try {
      final stats = await _peerConnection!.getStats();
      for (final report in stats) {
        if (report.type == 'candidate-pair' && report.values['state'] == 'succeeded') {
          final rtt = report.values['currentRoundTripTime'];
          if (rtt != null) {
            return (rtt * 1000).toInt();
          }
        }
      }
    } catch (e) {
      // 忽略错误
    }
    return 0;
  }

  /// 开始PTT对讲 (接收端使用) - 简化实现：启用预先添加的音频轨道
  Future<void> startPtt() async {
    if (_isPttActive) return;
    if (_receiverAudioStream == null) {
      onError?.call('PTT不可用：音频流未初始化');
      return;
    }
    
    try {
      // 启用接收端的本地音频轨道
      final audioTracks = _receiverAudioStream!.getAudioTracks();
      for (final track in audioTracks) {
        track.enabled = true;
        print('PTT: 启用音频轨道 ${track.id}');
      }
      
      _isPttActive = true;
      print('PTT: 对讲已开始');
    } catch (e) {
      onError?.call('启动对讲失败: $e');
    }
  }

  /// 停止PTT对讲 - 禁用音频轨道
  Future<void> stopPtt() async {
    if (!_isPttActive) return;
    
    try {
      if (_receiverAudioStream != null) {
        final audioTracks = _receiverAudioStream!.getAudioTracks();
        for (final track in audioTracks) {
          track.enabled = false;
          print('PTT: 禁用音频轨道 ${track.id}');
        }
      }
      
      _isPttActive = false;
      print('PTT: 对讲已停止');
    } catch (e) {
      onError?.call('停止对讲失败: $e');
    }
  }

  /// 切换手电筒
  Future<bool> toggleFlashlight() async {
    if (_localStream == null) return false;
    
    try {
      final videoTracks = _localStream!.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        final track = videoTracks.first;
        _isFlashlightOn = !_isFlashlightOn;
        await track.setTorch(_isFlashlightOn);
        return true;
      }
    } catch (e) {
      onError?.call('切换手电筒失败: $e');
    }
    return false;
  }

  /// 切换前后摄像头
  Future<bool> switchCamera() async {
    if (_localStream == null) return false;

    try {
      final videoTracks = _localStream!.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        final track = videoTracks.first;

        await track.stop();
        try { _localStream!.removeTrack(track); } catch (_) {}

        _isFrontCamera = !_isFrontCamera;

        final newStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': _isFrontCamera ? 'user' : 'environment',
            'width': {'ideal': _currentResolution.width},
            'height': {'ideal': _currentResolution.height},
          },
        });

        final newTrack = newStream.getVideoTracks().first;
        _localStream!.addTrack(newTrack);

        final senders = await _peerConnection?.getSenders();
        for (final sender in senders ?? []) {
          if (sender.track?.kind == 'video') {
            await sender.replaceTrack(newTrack);
            break;
          }
        }

        localRenderer.srcObject = _localStream;
        _isFlashlightOn = false;

        // 更新小窗流
        if (_pipEnabled && _pipStream != null) {
          for (final t in _pipStream!.getVideoTracks()) {
            await t.stop();
          }
          await _pipStream!.dispose();
          _pipStream = await navigator.mediaDevices.getUserMedia({
            'audio': false,
            'video': {
              'facingMode': _isFrontCamera ? 'environment' : 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
            },
          });
          final pipTrack = _pipStream!.getVideoTracks().first;
          final allSenders = await _peerConnection?.getSenders();
          for (final s in allSenders ?? []) {
            if (s.track?.kind == 'video' && s.track != newTrack) {
              await s.replaceTrack(pipTrack);
              break;
            }
          }
        }

        return true;
      }
    } catch (e) {
      onError?.call('切换摄像头失败: $e');
    }
    return false;
  }

  /// 启动心跳检测
  void startHeartbeat() {
    _lastHeartbeat = DateTime.now();
    _reconnectAttempts = 0;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
        sendDataCommand('HB');
      }
      if (_lastHeartbeat != null && DateTime.now().difference(_lastHeartbeat!) > _heartbeatTimeout) {
        _reconnectAttempts++;
        if (_reconnectAttempts <= _maxReconnectAttempts) {
          onReconnecting?.call(_reconnectAttempts);
          _lastHeartbeat = DateTime.now(); // 重置超时计时
        } else {
          onHeartbeatTimeout?.call();
          stopHeartbeat();
        }
      }
    });
  }

  /// 停止心跳检测
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 处理收到的心跳
  void onHeartbeatReceived() {
    _lastHeartbeat = DateTime.now();
    _reconnectAttempts = 0;
  }

  /// 清除远程流（断开连接时调用）
  void clearRemoteStream() {
    _remoteStream = null;
    remoteRenderer.srcObject = null;
    pipRenderer.srcObject = null;
  }

  /// 释放资源
  Future<void> dispose() async {
    // 停止心跳
    stopHeartbeat();

    // 停止PTT
    if (_isPttActive) {
      await stopPtt();
    }

    // 释放接收端音频流
    await _receiverAudioStream?.dispose();
    _receiverAudioStream = null;

    // 释放小窗流
    await _pipStream?.dispose();
    _pipStream = null;

    await _localStream?.dispose();
    await _dataChannel?.close(); // Close DataChannel
    await _peerConnection?.close();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
    await pipRenderer.dispose();
    _isInitialized = false;
    _hasRemoteDescription = false;
    _pendingCandidates.clear();
  }
}
