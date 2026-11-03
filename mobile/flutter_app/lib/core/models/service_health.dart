/// 服务连通状态（跨站点 / 下载器 / MoviePilot 等自建服务共用）。
library;

enum ServiceHealth {
  unknown('未测试'),
  ok('正常'),
  warning('需关注'),
  danger('异常');

  const ServiceHealth(this.label);

  final String label;

  static ServiceHealth fromName(String? value) => values.firstWhere(
        (ServiceHealth h) => h.name == value,
        orElse: () => ServiceHealth.unknown,
      );
}