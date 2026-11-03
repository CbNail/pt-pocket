import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/guardian_client.dart';
import 'package:pt_pocket/core/providers.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(guardianStatusProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('仪表盘'),
        actions: const [_LinkBadge()],
      ),
      body: status.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) {
          if (e is GuardianNotConfigured) {
            return const _HintCard(
              icon: Icons.settings_suggest_outlined,
              title: '还未连接监护室',
              subtitle: '到「设置」页填入 Guardian 地址和令牌，\n测试通过即自动保存。',
            );
          }
          return _HintCard(
            icon: Icons.cloud_off_outlined,
            title: '连接失败',
            subtitle: '错误信息：\n$e\n\n请检查 Guardian 是否在线、地址与令牌是否正确。',
          );
        },
        data: (sites) => RefreshIndicator(
          onRefresh: () async => ref.refresh(guardianStatusProvider.future),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            children: [
              _SummaryCard(sites: sites),
              const SizedBox(height: 8),
              for (final s in sites) _SiteTile(site: s),
            ],
          ),
        ),
      ),
    );
  }
}

/// 链路徽标：全状态兜底，任何情况都不渲染错误控件
class _LinkBadge extends ConsumerWidget {
  const _LinkBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(guardianLinkProvider).when(
          data: (link) {
            if (link == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                avatar:
                    Icon(link.isLan ? Icons.home_outlined : Icons.public, size: 16),
                label: Text(link.label, style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
              ),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.sites});
  final List<GuardianSite> sites;

  @override
  Widget build(BuildContext context) {
    final okCount = sites.where((s) => s.ok == true).length;
    final badCount = sites.where((s) => s.ok == false).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(child: _Stat(label: '监护站点', value: '${sites.length}')),
            Expanded(
                child: _Stat(
                    label: '正常', value: '$okCount', color: Colors.greenAccent)),
            Expanded(
                child: _Stat(
                    label: '异常', value: '$badCount', color: Colors.redAccent)),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: color, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _SiteTile extends StatelessWidget {
  const _SiteTile({required this.site});
  final GuardianSite site;

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    if (site.ok == true) {
      color = Colors.greenAccent;
      label = '正常';
    } else if (site.ok == false) {
      color = Colors.redAccent;
      label = site.alerted ? '病危告警' : '异常';
    } else {
      color = Colors.grey;
      label = '未知';
    }
    return Card(
      child: ListTile(
        leading: Icon(Icons.circle, color: color, size: 14),
        title: Text(site.name),
        subtitle: Text('${site.url}\n连续失败 ${site.fails} 次'),
        isThreeLine: true,
        trailing: Text(
          site.latencyMs == null ? label : '$label\n${site.latencyMs} ms',
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard(
      {required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, height: 1.5)),
          ],
        ),
      ),
    );
  }
}
