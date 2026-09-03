import 'package:flutter_test/flutter_test.dart';

import 'package:dynamite_app/models/firmware_release.dart';

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
        int cmp(String a, String b) => FirmwareVersion.tryParse(
          a,
        )!.compareTo(FirmwareVersion.tryParse(b)!);
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
      List<String> assets = const ['dynamite-sampler_v700P_x.bin'],
      int size = 1024,
    }) => GithubRelease(
      tag: tag,
      draft: draft,
      prerelease: prerelease,
      assets: [
        for (final name in assets)
          GithubAsset(
            name: name,
            size: size,
            url: Uri.https('x.test', '/$name'),
          ),
      ],
    );

    test('stable picks the newest non-prerelease with a board asset', () {
      final target = selectFirmwareTarget(
        [
          release('v0.4.0-beta.1', prerelease: true),
          release('v0.3.1'),
          release('v0.3.0'),
        ],
        board: 'v700P',
        channel: FirmwareChannel.stable,
      );
      expect(target?.tag, 'v0.3.1');
    });

    test('beta includes prereleases and orders them below their release', () {
      expect(
        selectFirmwareTarget(
          [release('v0.4.0-beta.2', prerelease: true), release('v0.3.1')],
          board: 'v700P',
          channel: FirmwareChannel.beta,
        )?.tag,
        'v0.4.0-beta.2',
      );
      expect(
        selectFirmwareTarget(
          [release('v0.4.0-beta.2', prerelease: true), release('v0.4.0')],
          board: 'v700P',
          channel: FirmwareChannel.beta,
        )?.tag,
        'v0.4.0',
      );
    });

    test('drafts, unparseable tags, and missing board assets are skipped', () {
      final target = selectFirmwareTarget(
        [
          release('v9.9.9', draft: true),
          release('nightly'),
          release('v0.5.0', assets: ['dynamite-sampler_other_board.bin']),
          release('v0.4.0'),
        ],
        board: 'v700P',
        channel: FirmwareChannel.beta,
      );
      expect(target?.tag, 'v0.4.0');
      expect(target?.assetName, 'dynamite-sampler_v700P_x.bin');
    });

    test('returns null when nothing qualifies', () {
      expect(
        selectFirmwareTarget(
          [release('v0.4.0-beta.1', prerelease: true)],
          board: 'v700P',
          channel: FirmwareChannel.stable,
        ),
        isNull,
      );
      expect(
        selectFirmwareTarget([], board: 'v700P', channel: FirmwareChannel.beta),
        isNull,
      );
    });

    test('picks up the sha256 sidecar when present', () {
      final target = selectFirmwareTarget(
        [
          release(
            'v0.4.0',
            assets: [
              'dynamite-sampler_v700P_v0.4.0.bin',
              'dynamite-sampler_v700P_v0.4.0.bin.sha256',
            ],
          ),
        ],
        board: 'v700P',
        channel: FirmwareChannel.stable,
      );
      expect(target?.sha256Url?.path, endsWith('.bin.sha256'));
    });
  });
}
