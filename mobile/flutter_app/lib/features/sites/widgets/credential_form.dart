import 'package:flutter/material.dart';

import '../../../core/models/pt_site.dart';
import '../../../core/theme/design_tokens.dart';

/// 凭据录入字段（按认证方式联动）。
///
/// 只负责采集输入，不负责落库；由调用方在保存时组装成凭据 Map 交给仓库，
/// 凭据本体统一写入本机安全存储。
class CredentialFields extends StatelessWidget {
  const CredentialFields({
    super.key,
    required this.authType,
    required this.cookieController,
    required this.secretController,
    required this.usernameController,
    required this.passwordController,
    this.uidController,
    this.deviceIdController,
    this.showApiKeyExtras = false,
  });

  final SiteAuthType authType;
  final TextEditingController cookieController;
  final TextEditingController secretController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;

  /// API Key 站点（如 M-Team）可附带的账号 UID 与设备标识；非该类型时忽略。
  final TextEditingController? uidController;
  final TextEditingController? deviceIdController;

  /// 是否展示 API Key 的扩展字段（M-Team 这类官方 API 需要 UID / Device ID）。
  final bool showApiKeyExtras;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    switch (authType) {
      case SiteAuthType.cookie:
        return TextField(
          controller: cookieController,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Cookie',
            hintText: 'name=value; name2=value2',
            alignLabelWithHint: true,
          ),
        );
      case SiteAuthType.passkey:
        return TextField(
          controller: secretController,
          decoration: const InputDecoration(
            labelText: 'Passkey',
            hintText: '站点发放的 Passkey',
          ),
        );
      case SiteAuthType.apiKey:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: secretController,
              decoration: const InputDecoration(
                labelText: 'API Key / 存取令牌',
                hintText: '站点控制台生成的密钥',
              ),
            ),
            if (showApiKeyExtras) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: uidController,
                decoration: const InputDecoration(
                  labelText: 'UID（可选）',
                  hintText: 'API 令牌所属账号的用户 ID',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: deviceIdController,
                decoration: const InputDecoration(
                  labelText: 'Device ID（可选）',
                  hintText: '用于浏览器查看详情页的设备标识',
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'UID / Device ID 仅部分站点（如 M-Team 官方 API）需要；不填则只用令牌。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        );
      case SiteAuthType.account:
        return Column(
          children: <Widget>[
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(labelText: '账号'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
          ],
        );
    }
  }
}

/// 组装凭据；全部为空时返回 null。
Map<String, dynamic>? buildCredentialMap(
  SiteAuthType authType, {
  required String cookie,
  required String secret,
  required String username,
  required String password,
  String uid = '',
  String deviceId = '',
}) {
  final DateTime now = DateTime.now();
  switch (authType) {
    case SiteAuthType.cookie:
      final String value = cookie.trim();
      if (value.isEmpty) return null;
      return <String, dynamic>{'type': authType.name, 'cookie': value, 'updatedAt': now.toIso8601String()};
    case SiteAuthType.passkey:
      final String passkey = secret.trim();
      if (passkey.isEmpty) return null;
      return <String, dynamic>{
        'type': authType.name,
        'passkey': passkey,
        'updatedAt': now.toIso8601String(),
      };
    case SiteAuthType.apiKey:
      final String value = secret.trim();
      if (value.isEmpty) return null;
      return <String, dynamic>{
        'type': authType.name,
        'apiKey': value,
        if (uid.trim().isNotEmpty) 'uid': uid.trim(),
        if (deviceId.trim().isNotEmpty) 'deviceId': deviceId.trim(),
        'updatedAt': now.toIso8601String(),
      };
    case SiteAuthType.account:
      if (username.trim().isEmpty || password.isEmpty) return null;
      return <String, dynamic>{
        'type': authType.name,
        'username': username.trim(),
        'password': password,
        'updatedAt': now.toIso8601String(),
      };
  }
}

/// 凭据摘要（不泄露内容，只描述类型与规模）。
String describeCredential(Map<String, dynamic>? credential) {
  if (credential == null) return '未录入';
  final String type = credential['type']?.toString() ?? 'unknown';
  final SiteAuthType authType = SiteAuthType.fromName(type);
  switch (authType) {
    case SiteAuthType.cookie:
      final String cookie = credential['cookie']?.toString() ?? '';
      final int pairs = cookie.split(';').where((String p) => p.contains('=')).length;
      return 'Cookie · $pairs 个键值';
    case SiteAuthType.passkey:
      return 'Passkey · 已保存';
    case SiteAuthType.apiKey:
      final String uid = credential['uid']?.toString() ?? '';
      return uid.isEmpty ? 'API Key · 已保存' : 'API Key · 已保存（UID $uid）';
    case SiteAuthType.account:
      return '账号 ${credential['username'] ?? ''} · 密码已保存';
  }
}