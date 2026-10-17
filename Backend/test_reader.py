"""Synthetic encrypted WeChat-shaped fixtures only. Never accesses user's WeChat."""
import base64
import os
import subprocess
import sys
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import reader as reader_module
from sqlcipher_probe import DB
from reader import snapshot, perform, literal, app_message_text
from capture_keys import verified


class ConversationListTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)/'db_storage'
        (self.root/'contact').mkdir(parents=True)
        (self.root/'message').mkdir()
        self.key = '9a'*32
        self.keys = {'contact/contact.db': {'enc_key': self.key}}
        with DB(self.root/'contact/contact.db', self.key, fixture_write=True) as db:
            db.query('CREATE TABLE contact(username TEXT,nick_name TEXT,remark TEXT,is_friend INTEGER)')
        self.request = {'root': str(self.root), 'account': hashlib.sha256(str(self.root.resolve()).encode()).hexdigest(),
                        'keys': {'keys': self.keys}, 'command': 'groups'}

    def contact(self, username, nickname, remark='', friend=False):
        with DB(self.root/'contact/contact.db', self.key, fixture_write=True) as db:
            db.query('INSERT INTO contact VALUES('+','.join(literal(v) for v in (username, nickname, remark))+','+str(int(friend))+')')

    def shard(self, filename, identities, messages):
        path = self.root/'message'/filename
        with DB(path, self.key, fixture_write=True) as db:
            db.query('CREATE TABLE Name2Id(user_name TEXT)')
            for identity in identities:
                db.query('INSERT INTO Name2Id VALUES('+literal(identity)+')')
            for chat, rows in messages.items():
                table = 'Msg_'+hashlib.md5(chat.encode()).hexdigest()
                db.query('CREATE TABLE '+table+'(local_id INTEGER,server_id INTEGER,local_type INTEGER,create_time INTEGER,real_sender_id INTEGER,message_content BLOB)')
                for index, (sender, body) in enumerate(rows, 1):
                    db.query('INSERT INTO '+table+' VALUES('+f'{index},{index},1,{99+index},{identities.index(sender)+1},'+literal(body)+')')
        self.keys['message/'+filename] = {'enc_key': self.key}
        return path

    def read(self, chat, start=100, end=200):
        return perform(dict(self.request, command='read', chat=chat, start=start, end=end))

    def ipc(self, request):
        return subprocess.run([sys.executable, str(Path(reader_module.__file__).resolve())],
                              input=json.dumps(request).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))

    def test_group_sender_and_unused_contacts_are_not_private_conversations(self):
        group, member, friend, empty, peer = 'room@chatroom', 'group_only_member', 'unused_friend', 'empty_peer', 'nonfriend_peer'
        self.contact(group, '群聊 🌙  A', '群备注')
        self.contact(member, '群内成员', friend=False)
        self.contact(friend, '无聊天好友', friend=True)
        self.contact(empty, '空私聊', friend=True)
        self.contact(peer, '实际非好友私聊', friend=False)
        self.shard('message_0.db', [member, friend, empty, peer],
                   {group: [(member, 'GROUP_ONLY_MARKER')], empty: [], peer: [(peer, 'NONFRIEND_MARKER')]})
        listed = perform(self.request)['groups']
        self.assertEqual({row['id'] for row in listed}, {group, peer})
        self.assertEqual(next(row for row in listed if row['id'] == group)['aliases'], ['群备注', '群聊 🌙  A'])
        # Excluding the member from the picker must not discard their sender name.
        self.assertEqual(self.read(group)['messages'][0]['sender'], '群内成员')
        self.assertEqual(self.read(peer)['messages'][0]['text'], 'NONFRIEND_MARKER')
        with self.assertRaisesRegex(RuntimeError, '^conversation_not_in_account$'):
            self.read(member)

    def test_contact_missing_identity_can_be_indexed_in_another_shard(self):
        chat, own = 'history_without_contact', 'synthetic_self'
        # The history can survive without a contact or a recent-session database.
        # Its identity is intentionally indexed only in the later shard.
        self.shard('message_0.db', [own], {chat: [(own, 'HISTORICAL_MARKER')]})
        self.shard('message_1.db', [chat], {})
        self.assertEqual(perform(self.request)['groups'], [{'id': chat, 'name': chat, 'aliases': []}])
        result = self.read(chat)
        self.assertEqual(result['name'], chat)
        self.assertEqual([row['text'] for row in result['messages']], ['HISTORICAL_MARKER'])

    def test_history_spanning_shards_is_listed_once_without_merging_same_names(self):
        first, second = 'first_peer', 'second_peer'
        self.contact(first, '同名')
        self.contact(second, '同名')
        self.shard('message_0.db', [first, second], {first: [(first, 'FIRST_MARKER')], second: [(second, 'SECOND_MARKER')]})
        self.shard('message_1.db', [first], {first: [(first, 'LATER_MARKER')]})
        listed = perform(self.request)['groups']
        self.assertEqual(len(listed), 2)
        self.assertEqual({row['id'] for row in listed}, {first, second})

    def test_only_supported_stores_supply_history_not_username_prefixes(self):
        supported, unsupported = 'gh_supported_fixture', 'gh_biz_only_fixture'
        self.contact(supported, '支持的本地会话')
        self.contact(unsupported, '仅在其他消息库中')
        self.shard('message_0.db', [supported, unsupported], {supported: [(supported, 'SUPPORTED_MARKER')]})
        self.shard('biz_message_0.db', [unsupported], {unsupported: [(unsupported, 'BIZ_ONLY_MARKER')]})
        self.assertEqual([row['id'] for row in perform(self.request)['groups']], [supported])

    def test_resource_and_fts_databases_are_not_conversation_shards(self):
        chat = 'synthetic_peer'
        self.contact(chat, '测试联系人')
        self.shard('message_0.db', [chat], {chat: [(chat, 'SUPPORTED_HISTORY')]})
        # Real layouts include these unrelated databases. Neither has Name2Id,
        # and neither key is supplied: listing/reading must never try to open them.
        for filename in ('message_resource.db', 'message_fts.db'):
            with DB(self.root/'message'/filename, self.key, fixture_write=True) as db:
                db.query('CREATE TABLE AuxiliaryMetadata(id INTEGER)')
        self.assertEqual([row['id'] for row in perform(self.request)['groups']], [chat])
        result = self.read(chat)
        self.assertEqual(result['scannedShards'], 1)
        self.assertEqual([row['text'] for row in result['messages']], ['SUPPORTED_HISTORY'])

    def test_missing_later_shard_key_never_returns_a_partial_list(self):
        chat = 'synthetic_peer'
        self.contact(chat, '测试联系人')
        self.shard('message_0.db', [chat], {chat: [(chat, 'FIRST_MARKER')]})
        self.shard('message_1.db', [chat], {chat: [(chat, 'LATER_MARKER')]})
        del self.keys['message/message_1.db']
        with self.assertRaisesRegex(RuntimeError, '^missing_key$'):
            perform(self.request)
        result = self.ipc(self.request)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout), {'error': 'missing_key'})

    def test_unreadable_later_shard_never_returns_a_partial_list(self):
        chat = 'synthetic_peer'
        self.contact(chat, '测试联系人')
        self.shard('message_0.db', [chat], {chat: [(chat, 'FIRST_MARKER')]})
        later = self.shard('message_1.db', [chat], {chat: [(chat, 'LATER_MARKER')]})
        later.write_bytes(b'UNREADABLE_SYNTHETIC_DATABASE')
        with self.assertRaises(RuntimeError):
            perform(self.request)
        result = self.ipc(self.request)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout), {'error': 'database_read_failed'})

    def test_listing_uses_readonly_metadata_and_sees_committed_wal(self):
        chat = 'synthetic_wal_peer'
        self.contact(chat, '测试联系人')
        path = self.shard('message_0.db', [chat], {chat: []})
        table = 'Msg_'+hashlib.md5(chat.encode()).hexdigest()
        original_query, original_snapshot = DB.query, reader_module.snapshot
        def metadata_query(db, sql):
            self.assertNotIn('message_content', sql.lower())
            self.assertNotRegex(sql.lower(), r'\bselect\s+\*')
            return original_query(db, sql)
        def contact_snapshot_only(path, key):
            self.assertNotEqual(path.parent.name, 'message', 'Listing copied an entire message shard')
            return original_snapshot(path, key)
        with DB(path, self.key, fixture_write=True) as writer:
            writer.query('PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA wal_checkpoint(TRUNCATE)')
            writer.query('INSERT INTO '+table+' VALUES(1,1,1,100,1,'+literal('BODY_MUST_NOT_BE_READ')+')')
            wal = Path(str(path)+'-wal')
            before = [hashlib.sha256(p.read_bytes()).digest() for p in (path, wal)]
            with patch.object(DB, 'query', metadata_query), patch.object(reader_module, 'snapshot', contact_snapshot_only):
                listed = perform(self.request)['groups']
            self.assertEqual([row['id'] for row in listed], [chat])
            self.assertEqual(before, [hashlib.sha256(p.read_bytes()).digest() for p in (path, wal)])
            writer.query('BEGIN; DELETE FROM '+table)
            self.assertEqual([row['id'] for row in perform(self.request)['groups']], [chat])
            writer.query('ROLLBACK')

    def test_existing_empty_table_and_outside_time_range_return_empty_messages(self):
        empty, peer = 'empty_peer', 'synthetic_peer'
        self.contact(empty, '空会话')
        self.contact(peer, '实际会话')
        self.shard('message_0.db', [empty, peer], {empty: [], peer: [(peer, 'OUTSIDE_WINDOW_MARKER')]})
        self.assertEqual([row['id'] for row in perform(self.request)['groups']], [peer])
        self.assertEqual(self.read(empty)['messages'], [])
        self.assertEqual(self.read(peer, start=101, end=200)['messages'], [])
        result = self.ipc(dict(self.request, command='read', chat='unknown_peer', start=100, end=200))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout), {'error': 'conversation_not_in_account'})


class DatabaseTests(unittest.TestCase):
    def test_private_conversation_scope_and_both_senders(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'db_storage'; (root/'contact').mkdir(parents=True); (root/'message').mkdir()
            key='78'*32; peer='synthetic_peer'; own='synthetic_self'; group='unrelated@chatroom'
            with DB(root/'contact/contact.db',key,fixture_write=True) as db:
                db.query('CREATE TABLE contact(username TEXT,nick_name TEXT,remark TEXT);')
                for values in [(peer,'同名联系人','朋友备注'),(own,'我',''),(group,'同名联系人','')]:
                    db.query('INSERT INTO contact VALUES('+','.join(literal(v) for v in values)+')')
            with DB(root/'message/message_0.db',key,fixture_write=True) as db:
                db.query('CREATE TABLE Name2Id(user_name TEXT); INSERT INTO Name2Id VALUES('+literal(peer)+'); INSERT INTO Name2Id VALUES('+literal(own)+');')
                for chat in [peer,group]:
                    table='Msg_'+hashlib.md5(chat.encode()).hexdigest()
                    db.query('CREATE TABLE '+table+'(local_id INTEGER,server_id INTEGER,local_type INTEGER,create_time INTEGER,real_sender_id INTEGER,message_content BLOB);')
                    for index,stamp,sender in [(1,99,1),(2,100,1),(3,110,2),(4,121,2)]:
                        db.query('INSERT INTO '+table+' VALUES('+f'{index},{index},1,{stamp},{sender},'+literal('PRIVATE' if chat==peer else 'UNRELATED_GROUP')+')')
            request={'root':str(root),'account':hashlib.sha256(str(root.resolve()).encode()).hexdigest(),'keys':{'keys':{'contact/contact.db':{'enc_key':key},'message/message_0.db':{'enc_key':key}}},'command':'groups'}
            conversations=perform(request)['groups']
            self.assertTrue(any(c['id']==peer and c['name']=='朋友备注' for c in conversations))
            request.update(command='read',chat=peer,start=100,end=120)
            result=perform(request)
            self.assertEqual([m['text'] for m in result['messages']],['PRIVATE','PRIVATE'])
            self.assertEqual([m['sender'] for m in result['messages']],['朋友备注','我'])
            self.assertEqual(result['chat'],peer)
            request['chat']='not_in_account'
            with self.assertRaises(RuntimeError): perform(request)

    def test_backup_reads_wal_and_rejects_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'fixture.db'; key='12'*32
            with DB(p,key,fixture_write=True) as writer:
                writer.query("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture(id INTEGER); INSERT INTO fixture VALUES(1); PRAGMA wal_checkpoint(TRUNCATE);")
                before=hashlib.sha256(p.read_bytes()).digest()
                writer.query('INSERT INTO fixture VALUES(2);')
                self.assertEqual(before,hashlib.sha256(p.read_bytes()).digest())
                with snapshot(p,key) as reader:
                    self.assertEqual(reader.query('SELECT count(*) AS n FROM fixture')[0]['n'],'2')
                    with self.assertRaises(RuntimeError): reader.query('INSERT INTO fixture VALUES(3)')
                self.assertEqual(before,hashlib.sha256(p.read_bytes()).digest())
                with self.assertRaises(RuntimeError):
                    with snapshot(p,'34'*32): pass
                writer.query('BEGIN; INSERT INTO fixture VALUES(3);')
                with snapshot(p,key) as reader: self.assertEqual(reader.query('SELECT count(*) AS n FROM fixture')[0]['n'],'2')
                writer.query('ROLLBACK; INSERT INTO fixture VALUES(4);')
                with snapshot(p,key) as reader: self.assertEqual(reader.query('SELECT count(*) AS n FROM fixture')[0]['n'],'3')

    def test_account_group_time_sender_evidence(self):
        # Keep fixture outside macOS /var↔/private/var URL aliasing.
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as folder:
            root=Path(folder)/'db_storage'; (root/'contact').mkdir(parents=True); (root/'message').mkdir()
            key='56'*32; chat='synthetic@chatroom'; other='other@chatroom'
            contact=root/'contact/contact.db'; message=root/'message/message_0.db'
            with DB(contact,key,fixture_write=True) as db:
                db.query('CREATE TABLE contact(username TEXT,nick_name TEXT,remark TEXT);')
                for values in [(chat,'人工群',''),(other,'人工群',''),('member1','人工成员','')]:
                    db.query('INSERT INTO contact VALUES('+','.join(literal(v) for v in values)+')')
            with DB(message,key,fixture_write=True) as db:
                db.query('CREATE TABLE Name2Id(user_name TEXT); INSERT INTO Name2Id VALUES(\'member1\');')
                for target in [chat,other]:
                    table='Msg_'+hashlib.md5(target.encode()).hexdigest()
                    db.query('CREATE TABLE '+table+'(local_id INTEGER,server_id INTEGER,local_type INTEGER,create_time INTEGER,real_sender_id INTEGER,message_content BLOB);')
                    for index,stamp in enumerate([99,100,150,200,201]):
                        body='member1:\n'+('人工原文' if target==chat else '另一群正文')
                        db.query('INSERT INTO '+table+' VALUES('+f'{index+1},{900+index},1,{stamp},1,'+literal(body)+')')
            account=hashlib.sha256(str(root.resolve()).encode()).hexdigest()
            request={'root':str(root),'account':account,'keys':{'keys':{'contact/contact.db':{'enc_key':key},'message/message_0.db':{'enc_key':key}}},'command':'read','chat':chat,'start':100,'end':200}
            result=perform(request)
            self.assertEqual(len(result['messages']),3)
            self.assertTrue(all(m['sender']=='人工成员' and m['text']=='人工原文' for m in result['messages']))
            self.assertEqual(result['messages'][0]['serverID'],'901')
            self.assertEqual(result['messages'][0]['database'],'message_0.db')
            table='Msg_'+hashlib.md5(chat.encode()).hexdigest()
            with DB(message,key,fixture_write=True) as db:
                db.query('BEGIN;'+''.join('INSERT INTO '+table+' VALUES('+str(10000+i)+',0,1,150,1,'+literal('synthetic long message '*8)+');' for i in range(6100))+'COMMIT;')
            extended=perform(request)
            self.assertEqual(len(extended['messages']),6103)
            self.assertGreater(sum(len(m['text'].encode()) for m in extended['messages']),80000)
            self.assertTrue(all(100<=m['timestamp']<=200 for m in extended['messages']))
            with DB(message,key,fixture_write=True) as db:
                db.query('INSERT INTO '+table+' VALUES(30000,30000,3,150,1,'+literal('<img md5="'+'a'*32+'"/>')+')')
            quote = '<msg><appmsg><title>REPLY_MARKER</title><type>57</type><refermsg><type>1</type><displayname>Quoted Person</displayname><content>QUOTED_MARKER &amp; original</content></refermsg></appmsg></msg>'
            card = '<msg><appmsg><title>CARD_MARKER</title><des>Card description</des><type>4</type><url>https://example.invalid/no-fetch</url></appmsg></msg>'
            forward = '<msg><appmsg><title>FORWARD_MARKER</title><type>19</type><recorditem><![CDATA[<recordinfo><datalist><dataitem datatype="1"><sourcename>Forwarded Person</sourcename><sourcetime>2000-01-01</sourcetime><datadesc>EMBEDDED_MARKER</datadesc></dataitem></datalist></recordinfo>]]></recorditem></appmsg></msg>'
            with DB(message,key,fixture_write=True) as db:
                for index,(kind,body) in enumerate([(49,quote),((57<<32)|49,quote),((4<<32)|49,card),((19<<32)|49,forward),(49,'malformed')]):
                    db.query('INSERT INTO '+table+' VALUES('+f'{31000+index},0,{kind},150,1,'+literal(body)+')')
            with_image=perform(request)
            self.assertEqual(len(with_image['messages']),6108)
            image=next(m for m in with_image['messages'] if m['type']==3)
            self.assertEqual(with_image['omittedMedia'],1)
            self.assertEqual(sum('REPLY_MARKER' in m['text'] for m in with_image['messages']),2)
            self.assertTrue(any('EMBEDDED_MARKER' in m['text'] for m in with_image['messages']))
            self.assertIsNone(image['image']['path'])
            self.assertEqual(image['database'],'message_0.db')
            image_dir=root.parent/'msg/attach'/hashlib.md5(chat.encode()).hexdigest()/'2026-10/Img'
            image_dir.mkdir(parents=True)
            image_file=image_dir/('a'*32+'.dat');image_file.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
            available=perform(request)
            image=next(m for m in available['messages'] if m['type']==3)
            self.assertEqual(image['image']['path'],str(image_file.resolve()))
            self.assertEqual(image['database'],'message_0.db')
            binary=os.environ.get('CHATFLOAT_READER_CHECK_BINARY')
            if binary:
                for output,expected_images in [(with_image,0),(available,1)]:
                    payload={'result':output,'root':str(root.resolve()),'start':100,'end':200,'expectedCount':6108,'expectedImages':expected_images}
                    checked=subprocess.run([binary,'--reader-check'],input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                    self.assertEqual(checked.returncode,0,checked.stdout.decode()+checked.stderr.decode())
                    report=json.loads(checked.stdout)
                    self.assertTrue(report['passed'])
                    self.assertEqual(report['visionOffImages'],0)
                    self.assertEqual(report['visionOnImages'],expected_images)
                    print('PASS perform → production Swift decode/session/snapshot/image preparation/prompt: '+('present' if expected_images else 'missing'))
            request['account']='wrong' 
            with self.assertRaises(RuntimeError): perform(request)
            request['account']=account; request['chat']='absent@chatroom'
            with self.assertRaises(RuntimeError): perform(request)
            request['chat']=chat; request['keys']['keys'].pop('message/message_0.db')
            with self.assertRaises(RuntimeError): perform(request)

    def test_rich_message_boundaries(self):
        xml='<msg><appmsg><type>57</type><title><![CDATA[Reply <literal>]]></title><refermsg><type>3</type><content>PRIVATE_IMAGE_XML</content><displayname>Someone</displayname></refermsg></appmsg></msg>'
        text=app_message_text('sender:\n'+xml)
        self.assertIn('Reply <literal>',text)
        self.assertIn('内嵌资料，不代表本次发言时间',text)
        self.assertIn('[引用图片，未附上]',text)
        self.assertNotIn('PRIVATE_IMAGE_XML',text)
        self.assertIsNone(app_message_text('<msg><appmsg>broken'))
        self.assertIsNone(app_message_text('<msg><appmsg><type>999</type></appmsg></msg>'))
        self.assertIsNone(app_message_text('<!DOCTYPE msg [<!ENTITY x "bad">]><msg><appmsg><title>&x;</title></appmsg></msg>'))

    def test_compressed_text_bounded_decode(self):
        import ctypes as C
        from reader import decompress
        lib=C.CDLL('/opt/homebrew/opt/zstd/lib/libzstd.dylib')
        body='人工压缩正文'.encode(); buffer=C.create_string_buffer(200)
        lib.ZSTD_compress.argtypes=[C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.c_int]; lib.ZSTD_compress.restype=C.c_size_t
        length=lib.ZSTD_compress(buffer,200,body,len(body),3)
        self.assertEqual(decompress(buffer.raw[:length]),body)
        self.assertEqual(decompress(b'plain'),b'plain')
        with self.assertRaises(RuntimeError): decompress(b'\x28\xb5\x2f\xfdcorrupt')

    def test_key_page_hmac_validation(self):
        import hmac
        key=b'k'*32; salt=b's'*16
        page=bytearray(salt+b'x'*(4096-16))
        mac_key=hashlib.pbkdf2_hmac('sha512',key,bytes(x^0x3a for x in salt),2,32)
        page[4032:]=hmac.new(mac_key,page[16:4032]+b'\x01\x00\x00\x00',hashlib.sha512).digest()
        self.assertTrue(verified(key,bytes(page)))
        page[100]^=1
        self.assertFalse(verified(key,bytes(page)))
        self.assertFalse(verified(b'0'*32,bytes(page)))

if __name__=='__main__': unittest.main()
