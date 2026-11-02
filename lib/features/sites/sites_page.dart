import 'package:flutter/material.dart';

class SitesPage extends StatelessWidget {
  const SitesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('站点')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.travel_explore, size: 56, color: Colors.white38),
            SizedBox(height: 16),
            Text('站点中心 · 施工中', style: TextStyle(fontSize: 18)),
            SizedBox(height: 8),
            Text('即将上线：站点列表 / 搜索 / 一键下载',
                style: TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}
