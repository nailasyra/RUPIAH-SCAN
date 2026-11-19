
import 'package:flutter/material.dart';
import 'screens/scan_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RupiahScanApp());
}

class RupiahScanApp extends StatelessWidget {
  const RupiahScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RupiahScan',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        scaffoldBackgroundColor: const Color(0xFF111116),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8957E5),
          brightness: Brightness.dark,
        ),
      ),
      home: const ScanScreen(),
    );
  }
}
