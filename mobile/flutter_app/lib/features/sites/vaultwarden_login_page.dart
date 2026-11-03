import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/models/pt_site.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import 'site_providers.dart';

/// 内置 WebView 登录（需求 1）。
///
/// 用途：
/// - 打开自建 Vaultwarden 查看站点账号密码（主密码只输入在 WebView 内，不进本应用存储）；
/// - 打开站点登录页手动完成登录，再抓取 `document.cookie` 写回站点凭据。
///
/// 已知边界：`document.cookie` 读不到 HttpOnly Cookie；
/// 若站点关键凭据是 HttpOnly，请改用 CookieCloud 导入。
class VaultwardenLoginPage extends ConsumerStatefulWidget {
  const VaultwardenLoginPage({super.key, required this.siteId, this.initialUrl});

  final String siteId;
  final String? initialUrl;

  @override
  ConsumerState<VaultwardenLoginPage> createState() => _VaultwardenLoginPageState();
}

class _VaultwardenLoginPageState extends ConsumerState<VaultwardenLoginPage> {
  late final TextEditingController _url =
      TextEditingController(text: widget.initialUrl ?? '');
  WebViewController? _controller;
  String _currentUrl = '';
  String _captured = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _load(widget.initialUrl!);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _load(String rawUrl) {
    final String value = rawUrl.trim();
    if (value.isEmpty) return;
    final Uri? uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri == null || uri.host.isEmpty) {
      setState(() => _error = '地址格式不正确');
      return;
    }
    try {
      _controller ??= WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (String url) {
              if (mounted) setState(() => _currentUrl = url);
            },
            onPageFinished: (String url) {
              if (mounted) setState(() => _currentUrl = url);
            },
            onWebResourceError: (WebResourceError error) {
              if (mounted) setState(() => _error = '页面加载失败：${error.description}');
            },
          ),
        );
      _controller!.loadRequest(uri);
      setState(() => _error = null);
    } catch (error) {
      setState(() => _error = '当前平台不支持内置 WebView：$error');
    }
  }

  Future<void> _captureCookies() async {
    final WebViewController? controller = _controller;
    if (controller == null) {
      setState(() => _error = '请先打开一个页面再抓取 Cookie');
      return;
    }
    setState(() => _busy = true);
    try {
      final Object raw = await controller.runJavaScriptReturningResult('document.cookie');
      final String value = raw is String ? _unquote(raw) : '$raw';
      if (!mounted) return;
      setState(() {
        _busy = false;
        _captured = value;
        _error = value.isEmpty ? '页面里没有可读取的 Cookie（可能都是 HttpOnly）' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '抓取失败：$error';
      });
    }
  }

  static String _unquote(String raw) {
    String value = raw;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value.replaceAll(r'\u003d', '=').replaceAll(r'\"', '"').trim();
  }

  Future<void> _applyToSite() async {
    final PtSite? site = ref.read(siteByIdProvider(widget.siteId));
    if (site == null) {
      setState(() => _error = '未找到目标站点，无法写回凭据');
      return;
    }
    if (_captured.isEmpty) {
      setState(() => _error = '还没有可写回的 Cookie');
      return;
    }
    await ref.read(siteListProvider.notifier).saveCredential(site.id, <String, dynamic>{
      'type': SiteAuthType.cookie.name,
      'cookie': _captured,
      'source': 'webview',
      'capturedUrl': _currentUrl,
      'updatedAt': DateTime.now().toIso8601String(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已把 Cookie 写回「${site.name}」')),
    );
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _captured));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cookie 已复制到剪贴板')),
    );
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.sites);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PtSite? site = ref.watch(siteByIdProvider(widget.siteId));
    final WebViewController? controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('内置登录'),
        leading: IconButton(icon: const Icon(Icons.close), tooltip: '取消', onPressed: _leave),
        actions: <Widget>[
          IconButton(
            tooltip: '抓取 Cookie',
            onPressed: _busy ? null : _captureCookies,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cookie_outlined),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '页面地址',
                      hintText: 'Vaultwarden 或站点登录页地址',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: () => _load(_url.text),
                  child: const Text('打开'),
                ),
              ],
            ),
          ),
          if (_captured.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SectionCard(
                title: '已抓取 Cookie',
                subtitle: '${_captured.length} 个字符',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _captured,
                      style: theme.textTheme.bodySmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: <Widget>[
                        if (site != null)
                          FilledButton.tonalIcon(
                            onPressed: _applyToSite,
                            icon: const Icon(Icons.save_outlined, size: AppSizes.iconSm),
                            label: Text('写回「${site.name}」'),
                          ),
                        OutlinedButton.icon(
                          onPressed: _copyToClipboard,
                          icon: const Icon(Icons.copy, size: AppSizes.iconSm),
                          label: const Text('复制'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (site != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
              child: Row(
                children: <Widget>[
                  const StatusBadge(label: '目标站点', tone: StatusTone.info, compact: true),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(site.name, style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.info_outline, size: AppSizes.iconSm, color: AppColors.warning),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(_error!, style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: controller == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        '填写 Vaultwarden 或站点登录页地址后点击「打开」，'
                        '在页面内手动完成登录；登录成功后可点右上角抓取 Cookie 写回站点。',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : WebViewWidget(controller: controller),
          ),
        ],
      ),
    );
  }
}