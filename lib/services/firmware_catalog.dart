import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/firmware_release.dart';

/// Where update checks and image downloads come from.
abstract interface class FirmwareCatalog {
  /// The channel's target release, or null when nothing qualifies. Throws
  /// on fetch failures (network, API) — "couldn't check" is surfaced, never
  /// silently treated as "up to date".
  Future<FirmwareRelease?> latestFor({required FirmwareChannel channel});

  /// The release's image bytes, size-checked against the asset metadata and
  /// SHA-256-verified when the release carries a sidecar. Throws
  /// [StateError] on any mismatch — the app never flashes bytes that failed
  /// the checks.
  Future<Uint8List> downloadImage(FirmwareRelease release);
}

/// GitHub Releases of the public firmware repo as the catalog. Selection
/// (channels, semver max) is pure, in `models/firmware_release.dart`; this
/// class is the fetching.
///
/// The raw releases list is used rather than the `/latest` endpoint:
/// `/latest` is "most recently published", not "newest version", and the
/// offer rule is direction-agnostic, so a backport flipping `/latest`
/// backward would downgrade-offer every newer unit. List + semver-max has
/// no such window.
class GithubReleaseCatalog implements FirmwareCatalog {
  GithubReleaseCatalog({http.Client? client})
    : _client = client ?? http.Client();

  // The firmware repo's releases are the single source of truth.
  static const _owner = 'K3Engineering';
  static const _repo = 'dynamite-sampler-firmware';
  static final _releasesUri = Uri.https(
    'api.github.com',
    '/repos/$_owner/$_repo/releases',
  );

  final http.Client _client;

  @override
  Future<FirmwareRelease?> latestFor({required FirmwareChannel channel}) async {
    final res = await _client.get(
      _releasesUri,
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (res.statusCode != 200) {
      throw StateError('Release check failed (HTTP ${res.statusCode})');
    }
    final releases = [
      for (final r in jsonDecode(res.body) as List<Object?>)
        GithubRelease.fromJson(r! as Map<String, Object?>),
    ];
    return selectFirmwareTarget(releases, channel: channel);
  }

  @override
  Future<Uint8List> downloadImage(FirmwareRelease release) async {
    final res = await _client.get(release.downloadUrl);
    if (res.statusCode != 200) {
      throw StateError(
        'Image download failed (HTTP ${res.statusCode}) for '
        '${release.assetName}',
      );
    }
    final bytes = res.bodyBytes;
    if (bytes.length != release.size) {
      throw StateError(
        'Image size mismatch for ${release.assetName}: '
        '${bytes.length} bytes, expected ${release.size}',
      );
    }
    final shaRes = await _client.get(release.sha256Url);
    if (shaRes.statusCode != 200) {
      throw StateError('Checksum download failed (HTTP ${shaRes.statusCode})');
    }
    final digest = sha256.convert(bytes).toString();
    final expected = shaRes.body.trim().split(RegExp(r'\s+')).first;
    if (expected != digest) {
      throw StateError('Image checksum mismatch for ${release.assetName}');
    }
    return bytes;
  }
}
