// Release metadata for OTA firmware updates: the version-compare and
// channel rules, the device-identity parse, and the release-selection
// contract with the firmware repo's CI. Network access lives in
// `firmware_catalog.dart` — everything here is pure.

/// Which release stream a device tracks. There is deliberately no
/// "nightly": nightlies are covered by the from-file flash path.
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

/// A semver-ish version parsed from a release tag (`v1.2.3`,
/// `v1.2.3-beta.4`). The leading `v` is optional on parse and always
/// rendered.
class FirmwareVersion implements Comparable<FirmwareVersion> {
  const FirmwareVersion(this.major, this.minor, this.patch, [this.prerelease]);

  final int major;
  final int minor;
  final int patch;

  /// The trailing prerelease (`beta.4`), or null for a release version.
  final String? prerelease;

  static final _pattern = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$',
  );

  static FirmwareVersion? tryParse(String tag) {
    final m = _pattern.firstMatch(tag.trim());
    if (m == null) return null;
    return FirmwareVersion(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      m[4],
    );
  }

  String get label =>
      'v$major.$minor.$patch${prerelease == null ? '' : '-$prerelease'}';

  @override
  int compareTo(FirmwareVersion other) {
    var c = major.compareTo(other.major);
    if (c != 0) return c;
    c = minor.compareTo(other.minor);
    if (c != 0) return c;
    c = patch.compareTo(other.patch);
    if (c != 0) return c;
    // Standard semver: a release outranks any of its prereleases.
    final pre = prerelease;
    final otherPre = other.prerelease;
    if (pre == null) return otherPre == null ? 0 : 1;
    if (otherPre == null) return -1;
    final segs = pre.split('.');
    final otherSegs = otherPre.split('.');
    for (var i = 0; i < segs.length && i < otherSegs.length; ++i) {
      final a = int.tryParse(segs[i]);
      final b = int.tryParse(otherSegs[i]);
      c = a != null && b != null
          ? a.compareTo(b)
          : segs[i].compareTo(otherSegs[i]);
      if (c != 0) return c;
    }
    return segs.length.compareTo(otherSegs.length);
  }

  @override
  String toString() => label;
}

/// The release a device should be running for its board and channel: one
/// matching image asset of one GitHub release.
class FirmwareRelease {
  const FirmwareRelease({
    required this.tag,
    required this.version,
    required this.board,
    required this.assetName,
    required this.size,
    required this.downloadUrl,
    required this.sha256Url,
  });

  /// The release tag as published, e.g. `v0.4.0-beta.1`.
  final String tag;
  final FirmwareVersion version;

  /// The board (firmware-rev prefix) this image is for.
  final String board;

  final String assetName;
  final int size;
  final Uri downloadUrl;

  /// The `.sha256` sidecar asset, when CI published one. Optional while the
  /// release pipeline is being set up; downloads verify when present.
  final Uri? sha256Url;
}

/// Minimal view of one GitHub release for selection — parsed from the API
/// by the catalog, constructed directly in tests.
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
/// identity key is the git-describe string — CI builds check out the tag
/// with a clean tree, so a release flashed properly describes exactly as
/// the tag (`v0.2.0`). This comparison is direction-agnostic by design:
/// "matches the channel target" is the only thing the update flow offers or
/// doesn't.
bool describeMatchesTag(String describe, String tag) =>
    _stripV(describe.trim()) == _stripV(tag.trim());

String _stripV(String s) {
  if (s.length < 2 || !s.startsWith('v')) return s;
  final next = s.codeUnitAt(1) - 0x30; // '0' == 0x30
  return next >= 0 && next <= 9 ? s.substring(1) : s;
}

/// Pick the release a [board] device on [channel] should run: the newest
/// (semver-max) non-draft release — stable excludes prereleases — whose
/// assets include this board's image (`dynamite-sampler_<board>_*.bin`).
/// Null when nothing qualifies (no releases yet, or none for this board).
///
/// TODO(runbook): tags are the version contract — never publish a backport
/// for an older line once a newer release exists; under the
/// direction-agnostic offer rule that would downgrade-offer the fleet.
FirmwareRelease? selectFirmwareTarget(
  List<GithubRelease> releases, {
  required String board,
  required FirmwareChannel channel,
}) {
  FirmwareRelease? best;
  for (final release in releases) {
    if (release.draft) continue;
    if (channel == FirmwareChannel.stable && release.prerelease) continue;
    final version = FirmwareVersion.tryParse(release.tag);
    if (version == null) continue;
    if (best != null && best.version.compareTo(version) >= 0) continue;
    final prefix = 'dynamite-sampler_${board}_';
    GithubAsset? image;
    for (final asset in release.assets) {
      if (asset.name.startsWith(prefix) && asset.name.endsWith('.bin')) {
        image = asset;
        break;
      }
    }
    if (image == null) continue;
    Uri? sha256Url;
    for (final asset in release.assets) {
      if (asset.name == '${image.name}.sha256') {
        sha256Url = asset.url;
        break;
      }
    }
    best = FirmwareRelease(
      tag: release.tag,
      version: version,
      board: board,
      assetName: image.name,
      size: image.size,
      downloadUrl: image.url,
      sha256Url: sha256Url,
    );
  }
  return best;
}
