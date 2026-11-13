"""An explicit Process now upload is not automatic recovery: the lookback does not refuse it."""

import pytest
from types import SimpleNamespace
from fastapi import HTTPException

from routers import sync
from tests.unit.test_sync_poll_limit import poll_client, poll_redis, poll_lua  # noqa: F401


def _past_lookback(monkeypatch, archives):
    monkeypatch.setattr(sync, 'prepare_sync_uploads', lambda files, *args, **kwargs: files)
    monkeypatch.setattr(sync, 'get_sync_ledger_fence_mode', lambda: sync.SyncLedgerFenceMode.ACTIVE)
    monkeypatch.setattr(sync.legacy_dark, 'current_mode', lambda *args: sync.legacy_dark.LegacySyncMode.DARK)
    monkeypatch.setattr(
        sync,
        'classify_sync_lane',
        lambda *args, **kwargs: SimpleNamespace(
            lane=sync.SyncLane.BACKFILL,
            trust=sync.CaptureTimeTrust.LEGACY,
            reason='lookback_exceeded',
            maximum_age_seconds=40 * 86400,
            automatic_recovery_allowed=False,
        ),
    )
    monkeypatch.setattr(sync, 'validate_backfill_uploads', lambda *args: None)
    monkeypatch.setattr(
        sync,
        'resolve_transcription_allowance',
        lambda *args: SimpleNamespace(managed=True, reason='plan_within_allowance'),
    )
    monkeypatch.setattr(sync, 'is_cloud_tasks_dispatch_enabled', lambda: False)
    monkeypatch.setattr(sync, 'has_byok_keys', lambda: False)
    monkeypatch.setattr(sync, '_retrieve_file_paths_v2', lambda *args: ['omi_1792152000.bin'])
    monkeypatch.setattr(sync, 'compute_sync_content_id', lambda *args: 'original-content')

    def archive(*args, **kwargs):
        archives.append(True)
        raise HTTPException(status_code=410, detail='synthetic admission checkpoint')

    monkeypatch.setattr(sync, 'archive_mobile_batch_raw_files', archive)


@pytest.mark.parametrize(
    'query, expected',
    [
        ('', 422),
        ('?explicit_user_request=false', 422),
        ('?explicit_user_request=true', 410),
    ],
)
def test_only_an_explicit_request_passes_the_automatic_recovery_lookback(poll_client, monkeypatch, query, expected):
    archives = []
    _past_lookback(monkeypatch, archives)
    response = poll_client.post(
        '/v2/sync-local-files' + query, files=[('files', ('audio_1000.bin', b'\0\0\0\0', 'application/octet-stream'))]
    )
    assert response.status_code == expected
    if expected == 422:
        assert response.json()['code'] == 'backfill_lookback_exceeded'
        assert archives == []
    else:
        # Admitted past the lookback to the same backfill path automatic uploads use.
        assert archives == [True]
