// Release metadata for OTA firmware updates: version compare, channel rules,
// and release selection. Network access lives in `firmware_catalog.dart`.

import 'package:pub_semver/pub_semver.dart' as semver;

/// Which release stream a device tracks. No "nightly": nightlies use the
/// from-file flash path.
enum FirmwareChannel {
  /// Published releases only.
  stable,

  /// Everything [stable] sees, plus GitHub prereleases (`vX.Y.Z-beta.N`).
  beta;

  String get label => switch (this) {
    FirmwareChannel.stable => 'Stable',
    FirmwareChannel.beta => 'Beta',
  };

  static FirmwareChannel fromName(String? name) =>
      values.asNameMap()[name] ?? FirmwareChannel.stable;
}

/// A version parsed from a release tag (`v1.2.3`, `v1.2.3-beta.4`). The
/// leading `v` is optional on parse, always rendered.
class FirmwareVersion implements Comparable<FirmwareVersion> {
  const FirmwareVersion(this.major, this.minor, this.patch, [this.prerelease]);

  final int major;
  final int minor;
  final int patch;

  /// The trailing prerelease (`beta.4`), or null for a release version.
  final String? prerelease;

  static FirmwareVersion? tryParse(String tag) {
    try {
      final v = semver.Version.parse(_stripV(tag.trim()));
      return FirmwareVersion(
        v.major,
        v.minor,
        v.patch,
        v.preRelease.isEmpty ? null : v.preRelease.join('.'),
      );
    } on FormatException {
      return null;
    }
  }

  semver.Version get _semver =>
      semver.Version(major, minor, patch, pre: prerelease);

  String get label => 'v$_semver';

  @override
  int compareTo(FirmwareVersion other) => _semver.compareTo(other._semver);

  @override
  String toString() => label;
}

/// The release a device should be running for its channel.
class FirmwareRelease {
  const FirmwareRelease({
    required this.tag,
    required this.version,
    required this.assetName,
    required this.size,
    required this.downloadUrl,
    required this.sha256Url,
  });

  /// The release tag as published, e.g. `0.4.0-beta.1`.
  final String tag;
  final FirmwareVersion version;

  final String assetName;
  final int size;
  final Uri downloadUrl;

  /// The `.sha256` sidecar asset; a release without one is not a candidate.
  final Uri sha256Url;
}

/// Minimal view of one GitHub release for selection.
class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.draft,
    required this.prerelease,
    required this.assets,
  });

  final String tag;
  final bool draft;
  final bool prerelease;
  final List<GithubAsset> assets;

  factory GithubRelease.fromJson(Map<String, Object?> json) {
    return GithubRelease(
      tag: json['tag_name']! as String,
      draft: json['draft']! as bool,
      prerelease: json['prerelease']! as bool,
      assets: [
        for (final a in json['assets']! as List<Object?>)
          GithubAsset.fromJson(a! as Map<String, Object?>),
      ],
    );
  }
}

class GithubAsset {
  const GithubAsset({
    required this.name,
    required this.size,
    required this.url,
  });

  final String name;
  final int size;
  final Uri url;

  factory GithubAsset.fromJson(Map<String, Object?> json) {
    return GithubAsset(
      name: json['name']! as String,
      size: json['size']! as int,
      url: Uri.parse(json['browser_download_url']! as String),
    );
  }
}

/// The firmware's `<board>|<git describe>` firmware-revision string.
({String board, String describe})? parseFirmwareRev(String rev) {
  final i = rev.indexOf('|');
  if (i <= 0 || i >= rev.length - 1) return null;
  return (board: rev.substring(0, i), describe: rev.substring(i + 1));
}

/// Whether the device is already running the bits of release [tag]. The
/// git-describe string matches the tag for a properly flashed release. The
/// comparison is direction-agnostic: only "matches the channel target" matters.
bool describeMatchesTag(String describe, String tag) =>
    _stripV(describe.trim()) == _stripV(tag.trim());

String _stripV(String s) {
  if (s.length < 2 || !s.startsWith('v')) return s;
  final next = s.codeUnitAt(1) - 0x30; // '0' == 0x30
  return next >= 0 && next <= 9 ? s.substring(1) : s;
}

/// The image asset name a release publishes. A wrong-chip image is the
/// device's own OTA validation's job to reject, not this name's.
String firmwareImageName(String tag) =>
    'dynamite-sampler-firmware-release-$tag.bin';

/// Pick the release a device on [channel] should run: the semver-newest
/// non-draft release (stable excludes prereleases) carrying both its image and
/// `.sha256` assets. Null when nothing qualifies.
///
/// TODO(runbook): tags are the version contract — never publish a backport
/// for an older line once a newer release exists; under the
/// direction-agnostic offer rule that would downgrade-offer the fleet.
FirmwareRelease? selectFirmwareTarget(
  List<GithubRelease> releases, {
  required FirmwareChannel channel,
}) {
  FirmwareRelease? best;
  for (final release in releases) {
    if (release.draft) continue;
    if (channel == FirmwareChannel.stable && release.prerelease) continue;
    final version = FirmwareVersion.tryParse(release.tag);
    if (version == null) continue;
    if (best != null && best.version.compareTo(version) >= 0) continue;
    final imageName = firmwareImageName(release.tag);
    GithubAsset? image;
    for (final asset in release.assets) {
      if (asset.name == imageName) {
        image = asset;
        break;
      }
    }
    if (image == null) continue;
    GithubAsset? sha256;
    for (final asset in release.assets) {
      if (asset.name == '${image.name}.sha256') {
        sha256 = asset;
        break;
      }
    }
    if (sha256 == null) continue;
    best = FirmwareRelease(
      tag: release.tag,
      version: version,
      assetName: image.name,
      size: image.size,
      downloadUrl: image.url,
      sha256Url: sha256.url,
    );
  }
  return best;
}
