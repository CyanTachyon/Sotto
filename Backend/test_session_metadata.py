"""Synthetic SQLCipher fixtures only. No live WeChat, Keychain or UI access."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from reader import literal
from session_metadata import SessionMetadataProbe
from sqlcipher_probe import DB


class SessionMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve() / 'db_storage'
        (self.root / 'session').mkdir(parents=True)
        self.path = self.root / 'session/session.db'
        self.key = 'ab' * 32
        self.ids = ['synthetic_A@chatroom', 'synthetic_B']
        with DB(self.path, self.key, fixture_write=True) as db:
            db.query('CREATE TABLE SessionTable(username TEXT, status INTEGER, unread_count INTEGER, '
                     'sort_timestamp INTEGER, last_msg_locald_id INTEGER, summary TEXT DEFAULT (' + literal('PRIVATE_DEFAULT') +
                     '), draft TEXT, draft_data BLOB, wxid_private_column TEXT, odd_type PRIVATE_TYPE_SECRET);')
            for index, identifier in enumerate(self.ids):
                db.query('INSERT INTO SessionTable VALUES(' + ','.join([
                    literal(identifier), str(index), '0', str(100 + index), str(700 + index),
                    literal('PRIVATE_SUMMARY'), literal('PRIVATE_DRAFT'), "x'50524956415445'",
                    literal('PRIVATE_COLUMN_VALUE'), literal('PRIVATE_ODD_VALUE')]) + ')')
            db.query('CREATE TABLE SessionDraft(username TEXT, window_id INTEGER, timestamp INTEGER, draft_data BLOB);')
            db.query('INSERT INTO SessionDraft VALUES(' + literal(self.ids[0]) + ',77,123,' + "x'50524956415445'" + ')')
            db.query('CREATE TABLE "wxid_PRIVATE_DYNAMIC_TABLE"(private_column TEXT);')
            db.query('INSERT INTO "wxid_PRIVATE_DYNAMIC_TABLE" VALUES(' + literal('PRIVATE_ROW') + ')')
        self.request = {'root': str(self.root), 'account': hashlib.sha256(str(self.root).encode()).hexdigest(),
                        'keys': {'keys': {'session/session.db': {'enc_key': self.key}}}}

    def tearDown(self):
        self.temp.cleanup()

    def probe(self):
        return SessionMetadataProbe(self.request)

    def assertPrivateValuesAbsent(self, value):
        encoded = json.dumps(value)
        for private in self.ids + ['PRIVATE_', self.key, str(self.root)]:
            self.assertNotIn(private, encoded)

    def test_schema_lists_types_without_values_defaults_or_dynamic_names(self):
        queries = []
        original = DB.query
        def record(db, sql):
            queries.append(sql)
            return original(db, sql)
        with patch.object(DB, 'query', record):
            result = self.probe().schema()
        self.assertPrivateValuesAbsent(result)
        named = {table['name']: table for table in result['tables'] if table['name']}
        self.assertEqual(set(named), {'SessionTable', 'SessionDraft'})
        columns = {column['name']: column for column in named['SessionTable']['columns'] if column['name']}
        self.assertEqual(columns['draft_data']['type'], 'BLOB')
        self.assertIsNone(columns['draft_data']['sample_kind'])
        self.assertIsNone(columns['summary']['sample_kind'])
        unknown = next(table for table in result['tables'] if table['name'] is None)
        self.assertFalse(unknown['sampling_allowed'])
        self.assertEqual(len(unknown['name_token']), 64)
        self.assertTrue(all('row_count' not in table for table in result['tables']))
        self.assertFalse(any('dflt_value' in sql or 'SELECT *' in sql or 'SELECT sql' in sql for sql in queries))
        self.assertEqual(result['disabled_path_candidates'], ['session.db'])
        self.assertFalse(result['current_ui_semantics_verified'])

    def test_schema_optional_counts_are_explicit(self):
        result = self.probe().schema(include_counts=True)
        counts = {table['name']: table['row_count'] for table in result['tables']}
        self.assertEqual(counts['SessionTable'], 2)
        self.assertEqual(counts['SessionDraft'], 1)
        self.assertPrivateValuesAbsent(result)

    def test_identifiers_stable_within_run_and_different_between_runs(self):
        probe = self.probe()
        fields = ['username', 'status', 'unread_count', 'sort_timestamp', 'last_msg_locald_id']
        first = probe.sample('SessionTable', fields)
        again = probe.sample('SessionTable', fields)
        independent = self.probe().sample('SessionTable', fields)
        self.assertEqual(first['rows'], again['rows'])
        self.assertNotEqual(first['rows'], independent['rows'])
        self.assertNotEqual(first['run_id'], independent['run_id'])
        self.assertEqual(sorted(row['status'] for row in first['rows']), [0, 1])
        self.assertTrue(all(isinstance(row['sort_timestamp'], int) for row in first['rows']))
        self.assertTrue(all(len(row['username']) == 64 and len(row['last_msg_locald_id']) == 64 for row in first['rows']))
        self.assertPrivateValuesAbsent(first)

    def test_draft_only_allows_id_window_and_timestamp(self):
        probe = self.probe()
        session = probe.sample('SessionTable', ['username', 'status'])
        draft = probe.sample('SessionDraft', ['username', 'window_id', 'timestamp'])
        self.assertIn(draft['rows'][0]['username'], [row['username'] for row in session['rows']])
        self.assertEqual(len(draft['rows'][0]['window_id']), 64)
        self.assertEqual(draft['rows'][0]['timestamp'], 123)
        self.assertPrivateValuesAbsent(draft)
        with self.assertRaisesRegex(RuntimeError, '^field_not_allowed$'):
            probe.sample('SessionDraft', ['draft_data'])

    def test_body_names_and_injected_fields_rejected_before_snapshot(self):
        probe = self.probe()
        forbidden = ['summary', 'draft', 'draft_data', 'preview', 'message_content', 'last_msg_sender',
                     'last_sender_display_name', 'wxid_private_column', 'username,summary',
                     'username); SELECT * FROM SessionTable;--', '*', 'rowid']
        with patch('session_metadata.snapshot', side_effect=AssertionError('must not access DB')):
            for field in forbidden:
                with self.subTest(field=field), self.assertRaisesRegex(RuntimeError, '^field_not_allowed$'):
                    probe.sample('SessionTable', [field])
            for fields in [[], ['username', 'username'], ['username', 1], 'username']:
                with self.assertRaisesRegex(RuntimeError, '^field_not_allowed$'):
                    probe.sample('SessionTable', fields)

    def test_unknown_or_injected_table_rejected_before_snapshot(self):
        probe = self.probe()
        with patch('session_metadata.snapshot', side_effect=AssertionError('must not access DB')):
            for table in ['contact', 'Msg_123', 'wxid_PRIVATE_DYNAMIC_TABLE', 'SessionTable;DROP TABLE SessionTable', None]:
                with self.subTest(table=table), self.assertRaisesRegex(RuntimeError, '^table_not_allowed$'):
                    probe.sample(table, ['username'])

    def test_path_allowlist_rejects_escape_and_other_databases(self):
        for path in ['../session.db', '/tmp/session.db', 'message/message_0.db', 'contact/contact.db',
                     'session.db', 'session/../session/session.db', 'session/session.db/extra']:
            with self.subTest(path=path), self.assertRaisesRegex(RuntimeError, '^path_not_allowed$'):
                SessionMetadataProbe(dict(self.request, relative_path=path))

    def test_database_and_sidecar_symlink_rejected(self):
        moved = self.root / 'original.db'
        self.path.rename(moved)
        self.path.symlink_to(moved)
        with self.assertRaisesRegex(RuntimeError, '^unsafe_database_path$'): self.probe()
        self.path.unlink(); moved.rename(self.path)
        wal = Path(str(self.path) + '-wal')
        wal.symlink_to(self.root / 'outside-target')
        with self.assertRaisesRegex(RuntimeError, '^unsafe_database_path$'): self.probe()

    def test_directory_symlink_rejected_and_path_rechecked(self):
        probe = self.probe()
        moved = self.root / 'redirected'
        (self.root / 'session').rename(moved)
        (self.root / 'session').symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, '^unsafe_database_path$'): probe.schema()
        with self.assertRaisesRegex(RuntimeError, '^unsafe_database_path$'): self.probe()

    def test_account_and_missing_key_rejected(self):
        with self.assertRaisesRegex(RuntimeError, '^account_mismatch$'):
            SessionMetadataProbe(dict(self.request, account='wrong'))
        with self.assertRaisesRegex(RuntimeError, '^missing_key$'):
            SessionMetadataProbe(dict(self.request, keys={'keys': {}}))
        with self.assertRaisesRegex(RuntimeError, '^missing_key$'):
            SessionMetadataProbe(dict(self.request, keys=[]))

    def test_runtime_blob_and_text_numeric_values_are_masked_and_rejected(self):
        probe = self.probe()
        for value in [literal('PRIVATE_NOT_A_NUMBER'), "x'50524956415445'"]:
            with DB(self.path, self.key, fixture_write=True) as db:
                db.query('UPDATE SessionTable SET status=' + value)
            queries, returned = [], []
            original = DB.query
            def record(db, sql):
                rows = original(db, sql)
                if ' AS t0,' in sql:
                    queries.append(sql); returned.extend(rows)
                return rows
            with patch.object(DB, 'query', record):
                with self.assertRaisesRegex(RuntimeError, '^invalid_scalar_type$'):
                    probe.sample('SessionTable', ['status'])
            self.assertTrue(queries)
            self.assertTrue(all(row['v0'] is None for row in returned))
            self.assertNotIn('PRIVATE', json.dumps(returned))
        with DB(self.path, self.key, fixture_write=True) as db:
            db.query("UPDATE SessionTable SET username=x'50524956415445'")
        with self.assertRaisesRegex(RuntimeError, '^invalid_scalar_type$'):
            probe.sample('SessionTable', ['username'])

    def test_missing_fields_and_limits_fail_without_partial_samples(self):
        probe = self.probe()
        with self.assertRaisesRegex(RuntimeError, '^column_missing$'):
            probe.sample('SessionTable', ['is_selected'])
        with self.assertRaisesRegex(RuntimeError, '^row_limit_exceeded$'):
            probe.sample('SessionTable', ['username'], limit=1)
        for limit in [0, -1, 5001, True, 1.5]:
            with self.assertRaisesRegex(RuntimeError, '^invalid_limit$'):
                probe.sample('SessionTable', ['username'], limit=limit)

    def test_declared_blob_column_cannot_be_sampled_even_with_scalar_storage(self):
        with DB(self.path, self.key, fixture_write=True) as db:
            db.query('DROP TABLE SessionDraft; CREATE TABLE SessionDraft(username BLOB, window_id INTEGER, timestamp INTEGER);')
            db.query('INSERT INTO SessionDraft VALUES(' + literal('PRIVATE_TEXT_IN_BLOB') + ',1,123)')
        probe = self.probe()
        table = next(table for table in probe.schema()['tables'] if table['name'] == 'SessionDraft')
        username = next(column for column in table['columns'] if column['name'] == 'username')
        self.assertIsNone(username['sample_kind'])
        with self.assertRaisesRegex(RuntimeError, '^invalid_scalar_type$'):
            probe.sample('SessionDraft', ['username'])

    def test_observations_see_committed_wal_only_and_do_not_change_source(self):
        probe = self.probe()
        with DB(self.path, self.key, fixture_write=True) as writer:
            writer.query('PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA wal_checkpoint(TRUNCATE);')
            before_base = self.path.read_bytes()
            writer.query('UPDATE SessionTable SET status=8 WHERE username=' + literal(self.ids[0]))
            wal = Path(str(self.path) + '-wal')
            before_wal = wal.read_bytes()
            result = probe.sample('SessionTable', ['username', 'status'])
            self.assertEqual(sorted(row['status'] for row in result['rows']), [1, 8])
            self.assertEqual(before_base, self.path.read_bytes())
            self.assertEqual(before_wal, wal.read_bytes())
            writer.query('BEGIN; UPDATE SessionTable SET status=9;')
            uncommitted = probe.sample('SessionTable', ['username', 'status'])
            self.assertEqual(uncommitted['rows'], result['rows'])
            writer.query('ROLLBACK;')

    def run_cli(self, requests):
        payload = '\n'.join(json.dumps(request) for request in requests) + '\n'
        return subprocess.run([sys.executable, str(Path(__file__).with_name('session_metadata.py'))],
            input=payload.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'), timeout=20)

    def test_cli_default_schema_and_multiline_samples_share_salt(self):
        result = self.run_cli([self.request,
            {'command': 'sample', 'table': 'SessionTable', 'fields': ['username', 'status']},
            {'command': 'sample', 'table': 'SessionTable', 'fields': ['username', 'status']}])
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b'')
        schema, first, second = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(schema['command'], 'schema')
        self.assertEqual(first['rows'], second['rows'])
        self.assertEqual(schema['run_id'], first['run_id'])
        self.assertPrivateValuesAbsent([schema, first, second])

    def test_cli_fixed_error_without_key_path_sql_or_traceback(self):
        wrong = dict(self.request, keys={'keys': {'session/session.db': {'enc_key': 'cd' * 32}}})
        result = self.run_cli([wrong])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout), {'error': 'metadata_read_failed'})
        self.assertEqual(result.stderr, b'')
        self.assertPrivateValuesAbsent(json.loads(result.stdout))
        result = self.run_cli([self.request, self.request])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1]), {'error': 'unexpected_credentials'})


if __name__ == '__main__':
    unittest.main(verbosity=2)
