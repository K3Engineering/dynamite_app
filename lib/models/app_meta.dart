/// App identity and version, resolved once at startup by the composition
/// root (main.dart, via package_info_plus) and injected where displayed
/// (the Settings About block) or stamped into exports.
class AppMeta {
  const AppMeta({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;

  /// Value stamped into the dynamite-csv metadata's `generator` field.
  String get generator => 'dynamite-flutter $version';

  /// Version string for the Settings About block, e.g. "1.2.3+45".
  String get versionLabel => '$version+$buildNumber';
}
