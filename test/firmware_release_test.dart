import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dynamite_app/models/firmware_release.dart';
import 'package:dynamite_app/services/firmware_catalog.dart';

void main() {
  group('FirmwareVersion', () {
    test('parses plain and prerelease tags, with and without leading v', () {
      final plain = FirmwareVersion.tryParse('v1.2.3')!;
      expect(plain.major, 1);
      expect(plain.prerelease, isNull);
      final beta = FirmwareVersion.tryParse('1.2.3-beta.4')!;
      expect(beta.prerelease, 'beta.4');
      expect(beta.label, 'v1.2.3-beta.4');
      expect(FirmwareVersion.tryParse('nightly'), isNull);
      expect(FirmwareVersion.tryParse('v1.2'), isNull);
    });

    test(
      'orders releases above their prereleases, prereleases among themselves',
      () {
        int cmp(String a, String b) =>
            FirmwareVersion.tryParse(a)!
                .compareTo(FirmwareVersion.tryParse(b)!);
        expect(cmp('v1.2.3', 'v1.2.3-beta.1'), greaterThan(0));
        expect(cmp('v1.2.3-beta.2', 'v1.2.3-beta.1'), greaterThan(0));
        expect(cmp('v1.2.3-beta.1', 'v1.2.2'), greaterThan(0));
        expect(cmp('v1.2.3-alpha', 'v1.2.3-beta'), lessThan(0));
        expect(cmp('v2.0.0', 'v1.9.9'), greaterThan(0));
      },
    );
  });

  group('identity helpers', () {
    test('parseFirmwareRev splits board and describe, rejects garbage', () {
      expect(parseFirmwareRev('v700P|v0.2.0-3-g8623578'), isNotNull);
      final rev = parseFirmwareRev('v700P|v0.2.0-3-g8623578')!;
      expect(rev.board, 'v700P');
      expect(rev.describe, 'v0.2.0-3-g8623578');
      expect(parseFirmwareRev('v0.2.0'), isNull);
      expect(parseFirmwareRev('v700P|'), isNull);
      expect(parseFirmwareRev('|v0.2.0'), isNull);
    });

    test('describeMatchesTag is the direction-agnostic identity check', () {
      expect(describeMatchesTag('v0.2.0', 'v0.2.0'), isTrue);
      expect(describeMatchesTag('0.2.0', 'v0.2.0'), isTrue);
      expect(describeMatchesTag('v0.2.0-5-g8623578', 'v0.2.0'), isFalse);
      expect(describeMatchesTag('v0.2.0', 'v0.3.0'), isFalse);
    });
  });

  group('selectFirmwareTarget', () {
    GithubRelease release(
      String tag, {
      bool draft = false,
      bool prerelease = false,
      List<String>? assets,
      int size = 1024,
    }) => GithubRelease(
      tag: tag,
      draft: draft,
      prerelease: prerelease,
      assets: [
        for (final name
            in assets ??
                [firmwareImageName(tag), '${firmwareImageName(tag)}.sha256'])
          GithubAsset(
            name: name,
            size: size,
            url: Uri.https('x.test', '/$name'),
          ),
      ],
    );

    test('stable picks the newest non-prerelease with an image asset', () {
      final target = selectFirmwareTarget([
        release('v0.4.0-beta.1', prerelease: true),
        release('v0.3.1'),
        release('v0.3.0'),
      ], channel: FirmwareChannel.stable);
      expect(target?.tag, 'v0.3.1');
    });

    test('beta includes prereleases and orders them below their release', () {
      expect(
        selectFirmwareTarget([
          release('v0.4.0-beta.2', prerelease: true),
          release('v0.3.1'),
        ], channel: FirmwareChannel.beta)?.tag,
        'v0.4.0-beta.2',
      );
      expect(
        selectFirmwareTarget([
          release('v0.4.0-beta.2', prerelease: true),
          release('v0.4.0'),
        ], channel: FirmwareChannel.beta)?.tag,
        'v0.4.0',
      );
    });

    test('drafts, unparseable tags, and asset-less releases are skipped', () {
      final target = selectFirmwareTarget([
        release('v9.9.9', draft: true),
        release('nightly'),
        release('v0.5.0', assets: ['some_other_artifact.zip']),
        release('v0.4.0'),
      ], channel: FirmwareChannel.beta);
      expect(target?.tag, 'v0.4.0');
      expect(target?.assetName, 'dynamite-sampler-firmware-release-v0.4.0.bin');
    });

    test('returns null when nothing qualifies', () {
      expect(
        selectFirmwareTarget([
          release('v0.4.0-beta.1', prerelease: true),
        ], channel: FirmwareChannel.stable),
        isNull,
      );
      expect(selectFirmwareTarget([], channel: FirmwareChannel.beta), isNull);
    });

    test('skips releases without the .sha256 sidecar', () {
      final target = selectFirmwareTarget([
        release('v0.5.0', assets: [firmwareImageName('v0.5.0')]),
        release('v0.4.0'),
      ], channel: FirmwareChannel.stable);
      expect(target?.tag, 'v0.4.0');
      expect(target?.sha256Url.path, endsWith('.bin.sha256'));
    });
  });

  group('GithubReleaseCatalog.latestFor', () {
    /// One well-formed GitHub release object, assets included.
    Map<String, Object?> releaseJson(String tag) => {
      'tag_name': tag,
      'draft': false,
      'prerelease': false,
      'assets': [
        for (final name in [
          firmwareImageName(tag),
          '${firmwareImageName(tag)}.sha256',
        ])
          {
            'name': name,
            'size': 1024,
            'browser_download_url': 'https://github.com/x/$name',
          },
      ],
    };

    GithubReleaseCatalog catalogReturning(List<Object?> body) =>
        GithubReleaseCatalog(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );

    test('a malformed entry fails the check instead of vanishing', () async {
      // The bad entry is the NEWEST: skipping it would answer "no update"
      // (or offer the older release) with nothing surfaced.
      final catalog = catalogReturning([
        releaseJson('v0.5.0'),
        {'tag_name': 42}, // malformed: tags are strings
      ]);
      await expectLater(
        () => catalog.latestFor(channel: FirmwareChannel.stable),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('release #1 is malformed'),
          ),
        ),
      );
    });

    test('a well-formed list still selects the newest release', () async {
      final catalog = catalogReturning([
        releaseJson('v0.4.0'),
        releaseJson('v0.5.0'),
      ]);
      expect(
        (await catalog.latestFor(channel: FirmwareChannel.stable))?.tag,
        'v0.5.0',
      );
    });
  });
}
