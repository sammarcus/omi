import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/models/local_recording.dart';
import 'package:omi/pages/conversations/sync_pending_work.dart';
import 'package:omi/providers/local_recordings_provider.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/sync/offline_sync_amounts.dart';

/// Transcribe Later recordings move only on the user's Process now. They must
/// never read as queued automatic work, count toward "Waiting on this phone",
/// or reach the server's lookback without a warning first.
void main() {
  Wal held({WalStatus status = WalStatus.miss, int retryCount = 0, int seconds = 60}) => Wal(
        timerStart: 1700000000,
        codec: BleAudioCodec.opus,
        seconds: seconds,
        status: status,
        retryCount: retryCount,
        holdForUser: true,
      );

  group('held display state', () {
    test('a held recording is held, not waiting or failed', () {
      for (final r in [0, 1, walMaxAutoRetries]) {
        expect(held(retryCount: r).syncDisplayState, WalSyncDisplayState.held, reason: 'retryCount=$r');
      }
      expect(held(status: WalStatus.inProgress).syncDisplayState, WalSyncDisplayState.held);
    });

    test('terminal and active states still win over the hold', () {
      expect(held(status: WalStatus.outsideRecoveryWindow).syncDisplayState, WalSyncDisplayState.outsideRecoveryWindow);
      expect(held(status: WalStatus.uploaded).syncDisplayState, WalSyncDisplayState.uploaded);
      expect((held()..isSyncing = true).syncDisplayState, WalSyncDisplayState.syncing);
    });

    test('held audio is not forward-moving work and is reported apart', () {
      final w = held(seconds: 120);
      expect(SyncPendingWork.isPendingWal(w), isFalse);
      expect(walIsSyncable(w), isFalse);
      final amounts = SyncPipelineAmounts.of([w]);
      expect(amounts.onPhoneSeconds, 0);
      expect(amounts.heldSeconds, 120);
    });
  });

  group('held lookback warning', () {
    LocalRecording rec(int timerStart) => LocalRecording.fromWal(
          Wal(timerStart: timerStart, codec: BleAudioCodec.opus, seconds: 60, holdForUser: true, filePath: 'x.bin'),
          filePath: '/tmp/x.bin',
          sizeBytes: 0,
        );
    const now = 1800000000;
    const day = 86400;

    test('warns only inside the final week before the lookback', () {
      expect(heldRecordingLookbackDeadline(rec(now - 10 * day), nowSeconds: now), isNull);
      final deadline = heldRecordingLookbackDeadline(rec(now - 25 * day), nowSeconds: now);
      expect(deadline, DateTime.fromMillisecondsSinceEpoch((now + 5 * day) * 1000));
      expect(heldRecordingLookbackDeadline(rec(now - 31 * day), nowSeconds: now), isNull);
      expect(heldRecordingLookbackDeadline(rec(0), nowSeconds: now), isNull);
    });
  });
}
