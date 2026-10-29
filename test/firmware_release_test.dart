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

  group('flashableReleases', () {
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

    List<String> tagsOf(List<GithubRelease> releases) => [
      for (final r in flashableReleases(releases)) r.tag,
    ];

    test('keeps every flashable release, newest first', () {
      expect(
        tagsOf([
          release('0.3.0'),
          release('0.4.0', prerelease: true),
          release('0.2.0'),
        ]),
        ['0.4.0', '0.3.0', '0.2.0'],
      );
    });

    test('drafts, unparseable tags, and asset-less releases are skipped', () {
      expect(
        tagsOf([
          release('v9.9.9', draft: true),
          release('nightly'),
          release('v0.5.0', assets: ['some_other_artifact.zip']),
          release('v0.4.0'),
        ]),
        ['v0.4.0'],
      );
      final only = flashableReleases([release('v0.4.0')]).single;
      expect(only.assetName, 'dynamite-sampler-firmware-release-v0.4.0.bin');
      expect(only.sha256Url.path, endsWith('.bin.sha256'));
    });

    test('skips releases without the .sha256 sidecar', () {
      expect(
        tagsOf([
          release('v0.5.0', assets: [firmwareImageName('v0.5.0')]),
          release('v0.4.0'),
        ]),
        ['v0.4.0'],
      );
    });

    test('one version spelled two ways keeps a total order', () {
      expect(tagsOf([release('v1.0.0'), release('1.0.0'), release('v0.9.0')]), [
        '1.0.0',
        'v1.0.0',
        'v0.9.0',
      ]);
    });
  });

  group('selectFirmwareTarget', () {
    FirmwareRelease release(String tag, {bool prerelease = false}) =>
        flashableRelease(
          GithubRelease(
            tag: tag,
            draft: false,
            prerelease: prerelease,
            assets: [
              for (final name in [
                firmwareImageName(tag),
                '${firmwareImageName(tag)}.sha256',
              ])
                GithubAsset(
                  name: name,
                  size: 1024,
                  url: Uri.https('x.test', '/$name'),
                ),
            ],
          ),
        )!;

    test('stable skips GitHub prereleases, beta includes them', () {
      final list = [
        release('0.4.0', prerelease: true),
        release('0.3.1'),
        release('0.3.0'),
      ];
      expect(
        selectFirmwareTarget(list, channel: FirmwareChannel.stable)?.tag,
        '0.3.1',
      );
      expect(
        selectFirmwareTarget(list, channel: FirmwareChannel.beta)?.tag,
        '0.4.0',
      );
    });

    test('newest is by version, not by list position', () {
      final list = [
        release('0.3.0'),
        release('0.3.1'),
        release('0.4.0', prerelease: true),
      ];
      expect(
        selectFirmwareTarget(list, channel: FirmwareChannel.stable)?.tag,
        '0.3.1',
      );
      expect(
        selectFirmwareTarget(list, channel: FirmwareChannel.beta)?.tag,
        '0.4.0',
      );
    });

    test('returns null when the channel has nothing', () {
      expect(
        selectFirmwareTarget([
          release('0.4.0', prerelease: true),
        ], channel: FirmwareChannel.stable),
        isNull,
      );
      expect(
        selectFirmwareTarget(const [], channel: FirmwareChannel.beta),
        isNull,
      );
    });
  });

  group('GithubReleaseCatalog.available', () {
    /// One well-formed GitHub release object, assets included.
    Map<String, Object?> releaseJson(
      String tag, {
      List<String>? assets,
      bool prerelease = false,
    }) => {
      'tag_name': tag,
      'draft': false,
      'prerelease': prerelease,
      'assets': [
        for (final name
            in assets ??
                [firmwareImageName(tag), '${firmwareImageName(tag)}.sha256'])
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
        catalog.available,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('release #1 is malformed'),
          ),
        ),
      );
    });

    test('returns the flashable releases newest first', () async {
      final catalog = catalogReturning([
        releaseJson('v0.4.0'),
        releaseJson('v0.6.0-beta.1'),
        releaseJson('v0.5.0', assets: const []),
        releaseJson('v0.6.0'),
      ]);
      expect(
        [for (final r in await catalog.available()) r.tag],
        ['v0.6.0', 'v0.6.0-beta.1', 'v0.4.0'],
      );
    });
  });
}
