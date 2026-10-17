"""Private stdin/stdout IPC only. SQLCipher source READONLY -> encrypted backup -> READONLY queries.
No network, message sending, original writes, plaintext database exports, or secret logging.
"""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from sqlcipher_probe import DB
from media import locate


def literal(value):
    return "CAST(x'" + value.encode('utf8').hex() + "' AS TEXT)"


def key_for(keys, root, path):
    rel = str(path.relative_to(root))
    value = keys.get(rel)
    if isinstance(value, dict): value = value.get('enc_key')
    if not isinstance(value, str) or not re.fullmatch('[0-9a-fA-F]{64}', value):
        raise RuntimeError('missing_key')
    return value


@contextmanager
def snapshot(path, key):
    # SQLite online backup reads committed WAL pages consistently. Destination remains encrypted.
    with tempfile.TemporaryDirectory(prefix='sotto-db-') as temp:
        os.chmod(temp, 0o700)
        copied = Path(temp)/'snapshot.db'
        with DB(path, key) as source:
            source.query('BEGIN; SELECT count(*) FROM sqlite_master;')
            with DB(copied, key, fixture_write=True) as target:
                lib = source.lib
                lib.sqlite3_backup_init.argtypes = [C.c_void_p, C.c_char_p, C.c_void_p, C.c_char_p]
                lib.sqlite3_backup_init.restype = C.c_void_p
                lib.sqlite3_backup_step.argtypes = [C.c_void_p, C.c_int]
                lib.sqlite3_backup_step.restype = C.c_int
                lib.sqlite3_backup_finish.argtypes = [C.c_void_p]
                lib.sqlite3_backup_finish.restype = C.c_int
                backup = lib.sqlite3_backup_init(target.ptr, b'main', source.ptr, b'main')
                if not backup: raise RuntimeError('snapshot_init_failed')
                started = time.monotonic()
                try:
                    while True:
                        status = lib.sqlite3_backup_step(backup, 256)
                        if status == 101: break
                        if status not in (0, 5, 6): raise RuntimeError('snapshot_failed')
                        if time.monotonic()-started > 35: raise RuntimeError('snapshot_busy_timeout')
                        if status in (5, 6): time.sleep(.03)
                finally:
                    result = lib.sqlite3_backup_finish(backup)
                if result: raise RuntimeError('snapshot_finish_failed')
            source.query('ROLLBACK;')
        os.chmod(copied, 0o600)
        with DB(copied, key) as db:
            yield db


def decompress(data):
    if not data.startswith(b'\x28\xb5\x2f\xfd'): return data
    here = Path(__file__).parent.parent/'Frameworks/libzstd.dylib'
    lib = C.CDLL(str(here) if here.exists() else '/opt/homebrew/opt/zstd/lib/libzstd.dylib')
    lib.ZSTD_getFrameContentSize.argtypes = [C.c_void_p, C.c_size_t]
    lib.ZSTD_getFrameContentSize.restype = C.c_ulonglong
    size = lib.ZSTD_getFrameContentSize(data, len(data))
    # Bound untrusted decompression. Unknown size -> decode into fixed 4 MB buffer.
    if size == 0xFFFFFFFFFFFFFFFF: size = 4_000_000
    if size > 4_000_000: raise RuntimeError('compressed_text_too_large')
    target = C.create_string_buffer(size)
    lib.ZSTD_decompress.argtypes = [C.c_void_p, C.c_size_t, C.c_void_p, C.c_size_t]
    lib.ZSTD_decompress.restype = C.c_size_t
    result = lib.ZSTD_decompress(target, size, data, len(data))
    lib.ZSTD_isError.argtypes = [C.c_size_t]; lib.ZSTD_isError.restype = C.c_uint
    if lib.ZSTD_isError(result): raise RuntimeError('compressed_text_invalid')
    return target.raw[:result]


def xml_root(text):
    # Parse only the XML already present in this selected message. Never resolve external resources.
    if '<!DOCTYPE' in text.upper() or '<!ENTITY' in text.upper(): return None
    starts = [p for p in (text.find('<msg'), text.find('<appmsg'), text.find('<recordinfo')) if p >= 0]
    if not starts: return None
    try: return ET.fromstring(text[min(starts):])
    except ET.ParseError: return None


def app_message_text(body, depth=0):
    if depth > 4: return '[内嵌消息层级过深，未展开]'
    doc = xml_root(body)
    if doc is None: return None
    app = doc if doc.tag == 'appmsg' else doc.find('.//appmsg')
    if app is None: return None
    value = lambda node, tag: (node.findtext(tag) or '').strip()
    title, description = value(app, 'title'), value(app, 'des')
    parts = list(dict.fromkeys(x for x in (title, description) if x))
    reference = app.find('refermsg')
    if reference is not None:
        kind, quoted = value(reference, 'type'), value(reference, 'content')
        if kind == '49': quoted = app_message_text(quoted, depth+1) or '[引用的卡片内容未解析]'
        elif kind != '1': quoted = {'3':'[引用图片，未附上]','34':'[引用语音，未转写]','43':'[引用视频，未解析]','47':'[引用表情]'}.get(kind, '[引用消息类型未解析]')
        if quoted: parts.append('引用内容（内嵌资料，不代表本次发言时间）：' + (value(reference, 'displayname') + '：' if value(reference, 'displayname') else '') + quoted)
    for record in app.findall('recorditem'):
        tree = xml_root(record.text or '') if len(record) == 0 else record
        if tree is None:
            parts.append('[合并转发的内嵌记录未解析]'); continue
        forwarded = []
        for item in tree.findall('.//dataitem'):
            text = value(item, 'datadesc') or value(item, 'content') or value(item, 'datatitle')
            if not text: text = '[内嵌附件或未解析消息]'
            sender, stamp = value(item, 'sourcename'), value(item, 'sourcetime')
            forwarded.append(' '.join(x for x in (sender, stamp) if x) + '：' + text)
        if forwarded: parts.append('合并转发内嵌资料（非当前群逐条发言）：\n' + '\n'.join(forwarded))
    for item in app.findall('.//mmreader/category/item'):
        article = '\n'.join(x for x in (value(item,'title'), value(item,'digest') or value(item,'summary')) if x)
        if article: parts.append(article)
    if value(app, 'url'): parts.append('卡片链接：' + value(app, 'url'))
    return '\n'.join(parts) if parts else None


def conversations_with_history(root, keys, paths, contacts, names):
    # Contacts and Name2Id include group senders who have never had a private chat.
    # They provide candidate identities only; a nonempty per-conversation message
    # table in a supported shard is the evidence needed to offer that conversation.
    candidates = set(names)
    nonempty_tables = set()
    for path in paths:
        # Listing must not copy large message databases or retrieve message bodies.
        # Each read-only transaction observes committed metadata and table existence
        # consistently, including WAL data. Never return a partial list on failure.
        with DB(path, key_for(keys, root, path)) as db:
            db.query('BEGIN')
            try:
                candidates.update(row['user_name'] for row in db.query('SELECT user_name FROM Name2Id')
                                  if row['user_name'])
                tables = db.query("SELECT name FROM sqlite_master WHERE type='table' AND name GLOB 'Msg_*'")
                for row in tables:
                    table = row['name']
                    # Only canonical hash table names are ever interpolated as SQL.
                    if re.fullmatch(r'Msg_[0-9a-f]{32}', table) and db.query('SELECT 1 FROM "'+table+'" LIMIT 1'):
                        nonempty_tables.add(table)
            finally:
                db.query('ROLLBACK')
    aliases = {}
    for row in contacts:
        if row['username']:
            aliases.setdefault(row['username'], set()).update(x for x in (row['nick_name'], row['remark']) if x)
    return [{'id': chat, 'name': names.get(chat, chat), 'aliases': sorted(aliases.get(chat, set()))}
            for chat in sorted(candidates)
            if 'Msg_' + hashlib.md5(chat.encode()).hexdigest() in nonempty_tables]


def perform(request):
    root = Path(request['root']).resolve(strict=True)
    if root.name != 'db_storage' or not root.is_dir(): raise RuntimeError('select_db_storage')
    account = hashlib.sha256(str(root).encode()).hexdigest()
    if request['account'] != account: raise RuntimeError('account_mismatch')
    keys = request['keys']['keys']
    if not isinstance(keys, dict): raise RuntimeError('invalid_keys')
    contact = root/'contact/contact.db'
    with snapshot(contact, key_for(keys, root, contact)) as db:
        contacts = db.query('SELECT username,nick_name,remark FROM contact')
    # Retain the complete map for naming group-message senders, even when they are
    # not eligible for the conversation picker themselves.
    names = {row['username']: (row['remark'] or row['nick_name'] or row['username']) for row in contacts if row['username']}
    if request['command'] not in ('groups', 'read'): raise RuntimeError('unsupported_command')
    # Resource/FTS databases share the message_ prefix but are not conversation
    # shards and do not expose Name2Id/Msg_<hash>. Only numbered shards belong to
    # this reader; their missing keys must still fail the entire operation.
    paths = sorted(path for path in (root/'message').glob('message_*.db')
                   if re.fullmatch(r'message_[0-9]+\.db', path.name))
    if not paths: raise RuntimeError('no_message_shards')
    if request['command'] == 'groups':
        return {'account': account, 'groups': conversations_with_history(root, keys, paths, contacts, names)}
    chat = request['chat']
    if not isinstance(chat, str) or not chat: raise RuntimeError('conversation_not_in_account')
    start, end = int(request['start']), int(request['end'])
    if start > end: raise RuntimeError('invalid_range')
    table = 'Msg_' + hashlib.md5(chat.encode()).hexdigest()
    known_identity, has_table = chat in names, False
    rows, scanned, omitted = [], 0, 0
    for path in paths:
        with snapshot(path, key_for(keys, root, path)) as db:
            scanned += 1
            sender_map = {r['rowid']: r['user_name'] for r in db.query('SELECT rowid,user_name FROM Name2Id')}
            known_identity = known_identity or chat in sender_map.values()
            if not db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name="+literal(table)): continue
            has_table = True
            columns = {r["name"] for r in db.query('PRAGMA table_info("'+table+'")')}
            packed_column = ",hex(packed_info_data) AS packed" if "packed_info_data" in columns else ""
            query = ('SELECT local_id,server_id,local_type,create_time,real_sender_id,hex(message_content) AS body'+packed_column+' FROM "'+table+'" '
                     'WHERE create_time>='+str(start)+' AND create_time<='+str(end)+' ORDER BY create_time,local_id')
            batch = db.query(query)
            for row in batch:
                sender_id = sender_map.get(row['real_sender_id'])
                kind = int(row['local_type'])
                text = None; image = None
                if kind == 1:
                    text = decompress(bytes.fromhex(row['body'] or '')).decode('utf8', 'strict')
                    if sender_id and text.startswith(sender_id+':\n'): text = text[len(sender_id)+2:]
                elif kind == 3:
                    body = decompress(bytes.fromhex(row['body'] or ''))
                    packed = bytes.fromhex(row.get('packed') or '')
                    image_path = locate(root,chat,body,packed)
                    image = {'path':image_path,'status':'本地图片待处理' if image_path else '本地附件未找到'}
                    text = '[图片]'
                elif kind & 0xffffffff == 49:
                    text = app_message_text(decompress(bytes.fromhex(row['body'] or '')).decode('utf8', 'strict'))
                    if not text:
                        omitted += 1
                        continue
                else:
                    omitted += 1
                    continue
                rows.append({'database': path.name, 'localID': row['local_id'], 'serverID': row['server_id'],
                             'timestamp': int(row['create_time']), 'senderID': sender_id,
                             'sender': names.get(sender_id, sender_id), 'text': text, 'type': kind, 'image':image})
    # An ID can be indexed in another shard. Validate against the complete scan
    # before returning anything, without a separate catalog/snapshot pass. A known
    # table that is empty, or has no rows in the requested range, remains an empty
    # query result rather than being reported as a foreign conversation.
    if not known_identity or not has_table: raise RuntimeError('conversation_not_in_account')
    rows.sort(key=lambda r: (r['timestamp'], r['database'], int(r['localID'])))
    return {'account': account, 'chat': chat, 'name': names.get(chat, chat), 'scannedShards': scanned,
            'omittedMedia': omitted, 'messages': rows, 'completeLocalQuery': True}


def main():
    os.umask(0o077)
    try:
        payload = sys.stdin.buffer.read(4_000_001)
        if len(payload)>4_000_000: raise RuntimeError('request_too_large')
        result = perform(json.loads(payload))
        print(json.dumps(result, ensure_ascii=False))
    except PermissionError:
        print(json.dumps({'error': 'permission_denied'})); return 2
    except Exception as error:
        # Only fixed codes, never sqlite messages, SQL, keys, account paths or message content.
        code = str(error)
        allowed = {'missing_key','invalid_keys','account_mismatch','select_db_storage','conversation_not_in_account','no_message_shards',
                   'unsupported_command','invalid_range','snapshot_init_failed','snapshot_failed','snapshot_finish_failed',
                   'snapshot_busy_timeout','compressed_text_invalid','compressed_text_too_large'}
        print(json.dumps({'error': code if code in allowed else 'database_read_failed'})); return 2
    return 0

if __name__ == '__main__': raise SystemExit(main())
