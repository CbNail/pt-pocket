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
  });

  final SiteAuthType authType;
  final TextEditingController cookieController;
  final TextEditingController secretController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;

  @override
  Widget build(BuildContext context) {
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
      case SiteAuthType.apiKey:
        return TextField(
          controller: secretController,
          decoration: InputDecoration(
            labelText: authType == SiteAuthType.passkey ? 'Passkey' : 'API Key',
            hintText: authType == SiteAuthType.passkey ? '站点发放的 Passkey' : '站点 API 密钥',
          ),
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
}) {
  final DateTime now = DateTime.now();
  switch (authType) {
    case SiteAuthType.cookie:
      final String value = cookie.trim();
      if (value.isEmpty) return null;
      return <String, dynamic>{'type': authType.name, 'cookie': value, 'updatedAt': now.toIso8601String()};
    case SiteAuthType.passkey:
    case SiteAuthType.apiKey:
      final String value = secret.trim();
      if (value.isEmpty) return null;
      return <String, dynamic>{'type': authType.name, authType.name: value, 'updatedAt': now.toIso8601String()};
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
      return 'API Key · 已保存';
    case SiteAuthType.account:
      return '账号 ${credential['username'] ?? ''} · 密码已保存';
  }
}