import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/role_selection_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const SimpleCar());
}

class SimpleCar extends StatelessWidget {
  const SimpleCar({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Simple Car',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const RoleSelectionScreen(),
    );
  }
}
