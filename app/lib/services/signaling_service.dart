import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 简易信令服务 - 通过TCP Socket进行信令交换
class SignalingService {
  ServerSocket? _serverSocket;
  Socket? _clientSocket;
  final int port;
  
  Function(String)? onMessage;
  Function()? onClientConnected;
  Function()? onError;

  SignalingService({this.port = 8765});

  /// 作为服务端启动 (发送端)
  Future<void> startServer() async {
    try {
      // 尝试监听IPv6地址
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv6,
        port,
        shared: true,
      );
      
      _serverSocket!.listen((socket) {
        _clientSocket = socket;
        onClientConnected?.call();
        
        String buffer = '';
        socket.listen(
          (data) {
            buffer += utf8.decode(data);
            while (buffer.contains('\n')) {
              final index = buffer.indexOf('\n');
              final message = buffer.substring(0, index);
              buffer = buffer.substring(index + 1);
              if (message.trim().isNotEmpty) {
                 onMessage?.call(message);
              }
            }
          },
          onError: (e) => onError?.call(),
          onDone: () => _clientSocket = null,
        );
      });
    } catch (e) {
      onError?.call();
      rethrow;
    }
  }

  /// 作为客户端连接 (接收端)
  Future<void> connectToServer(String ipv6Address, int serverPort) async {
    try {
      _clientSocket = await Socket.connect(
        InternetAddress(ipv6Address, type: InternetAddressType.IPv6),
        serverPort,
        timeout: const Duration(seconds: 10),
      );
      
      String buffer = '';
      _clientSocket!.listen(
        (data) {
          buffer += utf8.decode(data);
          while (buffer.contains('\n')) {
            final index = buffer.indexOf('\n');
            final message = buffer.substring(0, index);
            buffer = buffer.substring(index + 1);
            if (message.trim().isNotEmpty) {
               onMessage?.call(message);
            }
          }
        },
        onError: (e) => onError?.call(),
        onDone: () => _clientSocket = null,
      );
      
      onClientConnected?.call();
    } catch (e) {
      onError?.call();
      rethrow;
    }
  }

  /// 发送消息
  void sendMessage(String message) {
    _clientSocket?.write('$message\n');
  }

  /// 关闭连接
  Future<void> close() async {
    await _clientSocket?.close();
    await _serverSocket?.close();
    _clientSocket = null;
    _serverSocket = null;
  }
}
