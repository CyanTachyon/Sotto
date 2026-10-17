import unittest,tempfile,hashlib,struct,ctypes as C
from pathlib import Path
from media import decode,decode_v2,locate,perform,MAGIC

class MediaTests(unittest.TestCase):
 def test_plain_xor_and_v2(self):
  data=b'\x89PNG\r\n\x1a\n'+b'synthetic bytes'*20
  self.assertEqual(decode(data,[]),data)
  self.assertEqual(decode(bytes(x^77 for x in data),[]),data)
  key=b'1234567890abcdef';size=64;tail=25
  prefix=data[:size];pad=16-len(prefix)%16;prefix+=bytes([pad])*pad
  lib=C.CDLL('/usr/lib/system/libcommonCrypto.dylib');fn=lib.CCCrypt
  fn.argtypes=[C.c_uint,C.c_uint,C.c_uint,C.c_void_p,C.c_size_t,C.c_void_p,C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)]
  out=C.create_string_buffer(len(prefix)+16);n=C.c_size_t()
  self.assertEqual(fn(0,0,2,key,16,None,prefix,len(prefix),out,len(out),C.byref(n)),0)
  encrypted=MAGIC+struct.pack('<II',size,tail)+b'\0'+out.raw[:n.value]+data[size:-tail]+bytes(x^77 for x in data[-tail:])
  self.assertEqual(decode(encrypted,[(key,77)]),data)
  with self.assertRaises(ValueError):decode(encrypted,[(b'0'*16,77)])
  with self.assertRaises(ValueError):decode_v2(MAGIC+b'\xff'*30,key,77)
 def test_scoped_attachment_and_missing(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp)/'account/db_storage';root.mkdir(parents=True)
   chat='synthetic@chatroom';hash=hashlib.md5(chat.encode()).hexdigest();media='a'*32
   d=root.parent/'msg/attach'/hash/'2026-10/Img';d.mkdir(parents=True)
   image=d/(media+'.dat');data=b'\x89PNG\r\n\x1a\n' + b'fixture';image.write_bytes(data)
   self.assertEqual(locate(root,chat,b'<img md5="'+media.encode()+b'"/>',b''),str(image))
   self.assertIsNone(locate(root,'other@chatroom',b'<img md5="'+media.encode()+b'"/>',b''))
   result=perform({'root':str(root),'chat':chat,'paths':[str(image)]});self.assertEqual(result['images'][0]['status'],'decoded')
   denied=perform({'root':str(root),'chat':'other@chatroom','paths':[str(image)]});self.assertEqual(denied['images'][0]['status'],'outside_conversation');self.assertNotIn('data',denied['images'][0])
   outside=Path(tmp)/'outside.dat';outside.write_bytes(data);image.unlink();image.symlink_to(outside)
   self.assertIsNone(locate(root,chat,b'<img md5="'+media.encode()+b'"/>',b''))
if __name__=='__main__':unittest.main()
