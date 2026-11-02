import 'package:flutter/material.dart';

void main() => runApp(const PtPocketApp());

class PtPocketApp extends StatelessWidget {
  const PtPocketApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PT Pocket',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(title: const Text('PT Pocket')),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.rocket_launch, size: 64),
                SizedBox(height: 16),
                Text('流水线 OK · v0.1', style: TextStyle(fontSize: 20)),
                SizedBox(height: 8),
                Text('从今天起，这里开始长出你的 PT 一站式工具',
                    style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ),
      );
}
