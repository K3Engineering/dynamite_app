// Release metadata for OTA firmware updates: version compare, channel rules,
// and release selection. Network access lives in `firmware_catalog.dart`.

import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

/// Which release stream a device tracks. No "nightly": nightlies use the
/// from-file flash path.
enum FirmwareChannel {
  /// Published releases only.
  stable,

  /// Everything [stable] sees, plus GitHub prereleases.
  beta;

  String get label => switch (this) {
    .stable => 'Stable',
    .beta => 'Beta',
  };

  static FirmwareChannel fromName(String? name) =>
      values.asNameMap()[name] ?? FirmwareChannel.stable;
}

/// A version parsed from a release tag (`v1.2.3`, `v1.2.3-beta.4`). The
/// leading `v` is optional on parse, always rendered.
@immutable
class const FirmwareVersion(
  final int major,
  final int minor,
  final int patch, [
  // The trailing prerelease (`beta.4`); null for a release version.
  final String? prerelease,
]) implements Comparable<FirmwareVersion> {
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

/// A flashable firmware release (carries both its `.bin` image and `.sha256`
/// sidecar).
@immutable
class const FirmwareRelease({
  /// The release tag as published, e.g. `0.4.0`.
  required final String tag,
  required final FirmwareVersion version,

  /// GitHub's "Set as a pre-release" flag; excluded on [FirmwareChannel.stable].
  final bool prerelease = false,

  required final String assetName,
  required final int size,
  required final Uri downloadUrl,

  /// The `.sha256` sidecar asset; a release without one is not a candidate.
  required final Uri sha256Url,
});

/// Minimal view of one GitHub release for selection.
@immutable
class const GithubRelease({
  required final String tag,
  required final bool draft,
  required final bool prerelease,
  required final List<GithubAsset> assets,
}) {
  factory fromJson(Map<String, Object?> json) {
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

@immutable
class const GithubAsset({
  required final String name,
  required final int size,
  required final Uri url,
}) {
  factory fromJson(Map<String, Object?> json) {
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

/// The one release a device may flash, or null when this GitHub release is
/// not a flash candidate: a draft, a tag that isn't semver, or (most often,
/// right after tagging) a release whose image or `.sha256` sidecar is missing.
FirmwareRelease? flashableRelease(GithubRelease release) {
  if (release.draft) return null;
  final version = FirmwareVersion.tryParse(release.tag);
  if (version == null) return null;
  final imageName = firmwareImageName(release.tag);
  GithubAsset? image;
  for (final asset in release.assets) {
    if (asset.name == imageName) {
      image = asset;
      break;
    }
  }
  if (image == null) return null;
  for (final asset in release.assets) {
    if (asset.name == '${image.name}.sha256') {
      return FirmwareRelease(
        tag: release.tag,
        version: version,
        prerelease: release.prerelease,
        assetName: image.name,
        size: image.size,
        downloadUrl: image.url,
        sha256Url: asset.url,
      );
    }
  }
  return null;
}

/// Every [flashableRelease] of [releases], newest first. The update screen's
/// version picker renders this list and [selectFirmwareTarget] searches it, so
/// "what the picker offers" and "what a channel can resolve to" cannot drift.
///
/// TODO(runbook): tags are the version contract — never publish a backport
/// for an older line once a newer release exists; under the
/// direction-agnostic offer rule that would downgrade-offer the fleet.
List<FirmwareRelease> flashableReleases(List<GithubRelease> releases) {
  final out = <FirmwareRelease>[];
  for (final release in releases) {
    final r = flashableRelease(release);
    if (r != null) out.add(r);
  }
  // [List.sort] is unstable and `v1.0.0` / `1.0.0` are two tags for one
  // version, so ties break on the tag to keep the order total.
  out.sort((a, b) {
    final byVersion = b.version.compareTo(a.version);
    return byVersion != 0 ? byVersion : a.tag.compareTo(b.tag);
  });
  return out;
}

/// Pick the release a device on [channel] should run: the semver-newest
/// candidate (stable excludes [FirmwareRelease.prerelease]). Null when nothing
/// qualifies.
FirmwareRelease? selectFirmwareTarget(
  List<FirmwareRelease> candidates, {
  required FirmwareChannel channel,
}) {
  FirmwareRelease? best;
  for (final release in candidates) {
    if (channel == FirmwareChannel.stable && release.prerelease) continue;
    if (best != null && best.version.compareTo(release.version) >= 0) continue;
    best = release;
  }
  return best;
}
