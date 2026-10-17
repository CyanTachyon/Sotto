"""Bounded, read-only session metadata diagnostics; no current-chat inference.

Credentials enter only through stdin, never argv or files. The first NDJSON request
contains root/account/keys, command='schema' (default) or 'sample', and optional
sample table/fields/limit. Further lines contain only command/options and reuse the
same probe, hence the same random, unreported HMAC salt. Importers can similarly
reuse SessionMetadataProbe(request).schema() / .sample(table, fields).

Only session/session.db is enabled. The archived reference also mentions session.db
at the storage root, but that fallback is a candidate, not an automatic read path.
The production reader's encrypted online-backup snapshot supplies each observation.
No contact/message databases, plaintext exports, SQL text, previews or draft values
are read. Schema output redacts all names outside the explicit static vocabulary.
"""
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import secrets
import sys
import uuid

from reader import key_for, literal, snapshot

ALLOWED_RELATIVE_PATHS = frozenset({'session/session.db'})
CANDIDATE_RELATIVE_PATHS = ('session.db',)
MAX_INPUT_BYTES = 4_000_000
MAX_TABLES = 128
MAX_COLUMNS = 256
MAX_ROWS = 5000

# These are candidate scalar names, not assertions of current-UI semantics. Actual
# presence and type are checked against each snapshot before any row is sampled.
SESSION_IDENTIFIERS = frozenset({
    'username', 'user_name', 'session_id', 'talker_id',
    'unread_first_msg_srv_id', 'unread_first_pat_msg_local_id', 'last_msg_locald_id',
})
SESSION_NUMBERS = frozenset({
    'type', 'status', 'flag', 'flags', 'is_hidden', 'unread_count',
    'unread_first_pat_msg_sort_seq', 'last_timestamp', 'sort_timestamp',
    'last_clear_unread_timestamp', 'last_msg_type', 'last_msg_sub_type', 'last_msg_ext_type',
    'read_state', 'read_status', 'read_count', 'last_read_timestamp', 'last_read_time',
    'last_interaction_timestamp', 'last_interaction_time', 'last_active_time',
    'last_open_time', 'last_selected_time', 'is_selected', 'is_current', 'is_focused',
    'is_active', 'selected', 'current', 'focused',
})
SAMPLE_FIELDS = {
    'SessionTable': {**{name: 'identifier' for name in SESSION_IDENTIFIERS},
                     **{name: 'number' for name in SESSION_NUMBERS}},
    'SessionDraft': {'username': 'identifier', 'window_id': 'identifier', 'timestamp': 'number'},
}
# Listing these column names and types is safe; reading their values is forbidden.
CONTENT_COLUMN_NAMES = frozenset({
    'summary', 'draft', 'draft_data', 'message_content', 'content', 'body', 'preview',
    'last_msg_content', 'last_msg_sender', 'last_sender_display_name', 'name', 'nickname',
    'nick_name', 'remark', 'blob', 'ext_info', 'packed_info_data',
})
SCHEMA_COLUMN_NAMES = frozenset().union(*(set(fields) for fields in SAMPLE_FIELDS.values()),
                                      CONTENT_COLUMN_NAMES, {'id', 'create_time', 'update_time'})
SAFE_DECLARED_TYPES = frozenset({'', 'INT', 'INTEGER', 'BIGINT', 'SMALLINT', 'TINYINT',
    'UNSIGNED BIG INT', 'INT2', 'INT8', 'REAL', 'DOUBLE', 'DOUBLE PRECISION', 'FLOAT',
    'NUMERIC', 'DECIMAL', 'BOOLEAN', 'BOOL', 'DATE', 'DATETIME', 'TIMESTAMP', 'TEXT',
    'CLOB', 'VARCHAR', 'CHAR', 'BLOB'})
NUMERIC_DECLARED_TYPES = SAFE_DECLARED_TYPES - {'', 'TEXT', 'CLOB', 'VARCHAR', 'CHAR', 'BLOB'}
IDENTIFIER_DECLARED_TYPES = NUMERIC_DECLARED_TYPES | {'TEXT', 'VARCHAR', 'CHAR'}
ERROR_CODES = frozenset({'invalid_request', 'invalid_root', 'account_mismatch', 'path_not_allowed',
    'session_database_missing', 'unsafe_database_path', 'missing_key', 'unsupported_command',
    'unexpected_credentials', 'table_not_allowed', 'field_not_allowed', 'invalid_limit',
    'schema_limit_exceeded', 'table_missing', 'column_missing', 'row_limit_exceeded',
    'invalid_scalar_type', 'invalid_scalar_value', 'permission_denied', 'metadata_read_failed'})


def fail(code):
    raise RuntimeError(code)


def quoted_identifier(value):
    # SQLite identifiers are never interpolated unquoted, including unknown schema names.
    return '"' + value.replace('"', '""') + '"'


class SessionMetadataProbe:
    def __init__(self, request):
        if not isinstance(request, dict): fail('invalid_request')
        root_value = request.get('root')
        if not isinstance(root_value, str) or not root_value: fail('invalid_root')
        try:
            root = Path(root_value).resolve(strict=True)
        except (FileNotFoundError, NotADirectoryError):
            fail('invalid_root')
        if root.name != 'db_storage' or not root.is_dir(): fail('invalid_root')
        if request.get('account') != hashlib.sha256(str(root).encode()).hexdigest(): fail('account_mismatch')
        relative = request.get('relative_path', 'session/session.db')
        if not isinstance(relative, str) or relative not in ALLOWED_RELATIVE_PATHS: fail('path_not_allowed')
        manifest = request.get('keys')
        keys = manifest.get('keys') if isinstance(manifest, dict) else None
        if not isinstance(keys, dict): fail('missing_key')
        self._root = root
        self._relative = relative
        self._path = root / relative
        self._validate_path()
        self._key = key_for(keys, root, self._path)
        self._salt = secrets.token_bytes(32)
        self.run_id = uuid.uuid4().hex

    def _validate_path(self):
        # Reject symlink redirects of the directory, database, or SQLite sidecars.
        # Resolve anew before every snapshot; only this one known relative path is used.
        if self._path.parent.is_symlink() or self._path.is_symlink(): fail('unsafe_database_path')
        if not self._path.is_file(): fail('session_database_missing')
        if self._path.resolve(strict=True) != self._path: fail('unsafe_database_path')
        for suffix in ('-wal', '-shm', '-journal'):
            if Path(str(self._path) + suffix).is_symlink(): fail('unsafe_database_path')

    def _token(self, domain, value):
        message = (domain + '\0' + value).encode('utf8')
        return hmac.new(self._salt, message, hashlib.sha256).hexdigest()

    def _base(self, command):
        return {'version': 1, 'command': command, 'run_id': self.run_id,
                'relative_path': self._relative, 'read_only': True,
                'current_ui_semantics_verified': False}

    def _tables(self, db):
        rows = db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT " + str(MAX_TABLES + 1))
        if len(rows) > MAX_TABLES: fail('schema_limit_exceeded')
        return [row['name'] for row in rows]

    def _columns(self, db, table):
        # Do not select default values or CREATE TABLE SQL: they can embed content.
        rows = db.query('SELECT name,type FROM pragma_table_info(' + literal(table) + ') LIMIT ' + str(MAX_COLUMNS + 1))
        if len(rows) > MAX_COLUMNS: fail('schema_limit_exceeded')
        return rows

    def _sample_kind(self, table, field, declared):
        kind = SAMPLE_FIELDS.get(table, {}).get(field)
        allowed = IDENTIFIER_DECLARED_TYPES if kind == 'identifier' else NUMERIC_DECLARED_TYPES
        return kind if kind and declared.strip().upper() in allowed else None

    def schema(self, *, include_counts=False):
        if not isinstance(include_counts, bool): fail('invalid_request')
        self._validate_path()
        result = self._base('schema')
        result['disabled_path_candidates'] = list(CANDIDATE_RELATIVE_PATHS)
        tables = []
        with snapshot(self._path, self._key) as db:
            for table in self._tables(db):
                known_table = table in SAMPLE_FIELDS
                item = {'name': table if known_table else None,
                        'name_token': self._token('table', table), 'sampling_allowed': known_table,
                        'columns': []}
                for column in self._columns(db, table):
                    name = column['name']
                    declared = (column['type'] or '').strip().upper()
                    known_column = known_table and name in SCHEMA_COLUMN_NAMES
                    entry = {'name': name if known_column else None,
                             'name_token': self._token('column:' + table, name),
                             'type': declared if declared in SAFE_DECLARED_TYPES else 'OTHER',
                             'sample_kind': self._sample_kind(table, name, declared)}
                    if declared not in SAFE_DECLARED_TYPES:
                        entry['type_token'] = self._token('declared_type', declared)
                    item['columns'].append(entry)
                if include_counts:
                    item['row_count'] = int(db.query('SELECT count(*) AS n FROM ' + quoted_identifier(table))[0]['n'])
                tables.append(item)
        result['tables'] = tables
        return result

    def sample(self, table, fields, *, limit=500):
        if not isinstance(table, str) or table not in SAMPLE_FIELDS: fail('table_not_allowed')
        if (not isinstance(fields, list) or not fields or len(fields) > 48 or
                any(not isinstance(field, str) or field not in SAMPLE_FIELDS[table] for field in fields) or
                len(set(fields)) != len(fields)):
            fail('field_not_allowed')
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_ROWS: fail('invalid_limit')
        self._validate_path()
        with snapshot(self._path, self._key) as db:
            if table not in self._tables(db): fail('table_missing')
            columns = {column['name']: column['type'] for column in self._columns(db, table)}
            if any(field not in columns for field in fields): fail('column_missing')
            if any(self._sample_kind(table, field, columns[field] or '') is None for field in fields):
                fail('invalid_scalar_type')
            pieces = []
            for index, field in enumerate(fields):
                quoted = quoted_identifier(field)
                allowed_types = "'text','integer'" if SAMPLE_FIELDS[table][field] == 'identifier' else "'integer','real'"
                # SQL itself masks values of forbidden runtime types. A BLOB/TEXT
                # pretending to be a numeric status never enters Python or output.
                pieces += ['typeof(' + quoted + ') AS t' + str(index),
                           'CASE WHEN typeof(' + quoted + ') IN (' + allowed_types + ') THEN ' + quoted +
                           ' ELSE NULL END AS v' + str(index)]
            rows = db.query('SELECT ' + ','.join(pieces) + ' FROM ' + quoted_identifier(table) + ' LIMIT ' + str(limit + 1))
        if len(rows) > limit: fail('row_limit_exceeded')
        sampled = []
        for row in rows:
            output = {}
            for index, field in enumerate(fields):
                storage, value = row['t' + str(index)], row['v' + str(index)]
                kind = SAMPLE_FIELDS[table][field]
                if storage == 'null':
                    output[field] = None
                elif kind == 'identifier':
                    if storage not in ('text', 'integer'): fail('invalid_scalar_type')
                    if not isinstance(value, str) or len(value.encode('utf8')) > 4096: fail('invalid_scalar_value')
                    # Same username maps identically across SessionTable/SessionDraft.
                    output[field] = self._token('identifier', value)
                else:
                    if storage not in ('integer', 'real'): fail('invalid_scalar_type')
                    try:
                        number = int(value) if storage == 'integer' else float(value)
                    except (ValueError, TypeError, OverflowError):
                        fail('invalid_scalar_value')
                    if isinstance(number, float) and not math.isfinite(number): fail('invalid_scalar_value')
                    output[field] = number
            sampled.append(output)
        sampled.sort(key=lambda row: json.dumps(row, sort_keys=True, separators=(',', ':')))
        result = self._base('sample')
        result.update(table=table, fields=fields, row_count=len(sampled), complete=True, rows=sampled)
        return result

    def perform(self, request):
        if not isinstance(request, dict): fail('invalid_request')
        command = request.get('command', 'schema')
        if command == 'schema': return self.schema(include_counts=request.get('include_counts', False))
        if command == 'sample': return self.sample(request.get('table'), request.get('fields'), limit=request.get('limit', 500))
        fail('unsupported_command')


def error_code(error):
    if isinstance(error, PermissionError): return 'permission_denied'
    code = str(error)
    return code if code in ERROR_CODES else 'metadata_read_failed'


def main():
    os.umask(0o077)
    probe = None
    while True:
        payload = sys.stdin.buffer.readline(MAX_INPUT_BYTES + 1)
        if not payload: return 0
        try:
            if len(payload) > MAX_INPUT_BYTES: fail('invalid_request')
            request = json.loads(payload)
            if not isinstance(request, dict): fail('invalid_request')
            if probe is None:
                probe = SessionMetadataProbe(request)
            elif any(name in request for name in ('root', 'account', 'keys', 'relative_path')):
                fail('unexpected_credentials')
            result = probe.perform(request)
            print(json.dumps(result, ensure_ascii=False), flush=True)
        except Exception as error:
            # No traceback, native error, source path, SQL, key or row value is emitted.
            print(json.dumps({'error': error_code(error)}), flush=True)
            return 2


if __name__ == '__main__':
    sys.exit(main())
