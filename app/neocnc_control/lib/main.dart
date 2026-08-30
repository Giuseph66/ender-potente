import 'package:flutter/material.dart';

import 'core/theme/neocnc_theme.dart';
import 'features/dashboard/presentation/cnc_dashboard.dart';

void main() {
  runApp(const NeoCncApp());
}

class NeoCncApp extends StatelessWidget {
  const NeoCncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NeoCNC Control',
      debugShowCheckedModeBanner: false,
      theme: NeoCncTheme.dark(),
      home: const CncDashboard(),
    );
  }
}
