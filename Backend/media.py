"""Scoped local WeChat images. No network, OCR, process inspection or persisted keys.
V2 format: 15-byte header, PKCS7 AES-ECB prefix, plain middle, XOR tail.
macOS disk-derived key candidates are accepted only after image magic validation.
"""
import base64,ctypes as C,hashlib,json,re,struct,sys
from pathlib import Path

MAGIC=b'\x07\x08V2\x08\x07'
MAX_FILE=40*1024*1024

def kind(data):
    if data.startswith(b'\xff\xd8\xff'):return 'jpeg'
    if data.startswith(b'\x89PNG\r\n\x1a\n'):return 'png'
    if data.startswith((b'GIF87a',b'GIF89a')):return 'gif'
    if data[:4]==b'RIFF' and data[8:12]==b'WEBP':return 'webp'
    if data.startswith(b'wxgf'):return 'wxgf'
    if len(data)>12 and data[4:8]==b'ftyp':return 'heif'
    return None

def aes(data,key):
    lib=C.CDLL('/usr/lib/system/libcommonCrypto.dylib')
    fn=lib.CCCrypt;fn.argtypes=[C.c_uint,C.c_uint,C.c_uint,C.c_void_p,C.c_size_t,C.c_void_p,C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)];fn.restype=C.c_int
    out=C.create_string_buffer(len(data)+16);count=C.c_size_t()
    if fn(1,0,2,key,len(key),None,data,len(data),out,len(out),C.byref(count)):raise ValueError('decrypt_failed')
    return out.raw[:count.value]

def decode_v2(data,key,xor):
    if len(data)<31:raise ValueError('invalid_v2')
    size,tail=struct.unpack('<II',data[6:14]);aligned=(size//16+1)*16
    if aligned>len(data)-15 or tail>len(data)-15-aligned:raise ValueError('invalid_v2')
    block=aes(data[15:15+aligned],key);pad=block[-1]
    if not 1<=pad<=16 or block[-pad:]!=bytes([pad])*pad:raise ValueError('invalid_padding')
    prefix=block[:-pad]
    if len(prefix)!=size:raise ValueError('invalid_prefix')
    rest=data[15+aligned:]; plain=prefix+(rest[:-tail] if tail else rest)+(bytes(x^xor for x in rest[-tail:]) if tail else b'')
    if not kind(plain):raise ValueError('unknown_format')
    return plain

def candidates(root):
    account=root.parent.name
    cleaned=re.match(r'^(wxid_[^_]+)',account)
    cleaned=cleaned.group(1) if cleaned else re.sub(r'_[a-zA-Z0-9]{4}$','',account)
    base=Path.home()/'Library/Containers/com.tencent.xinWeChat/Data'
    dirs=[base/'Documents/app_data/net/kvcomm',base/'Library/Application Support/com.tencent.xinWeChat/xwechat/net/kvcomm',base/'Library/Application Support/com.tencent.xinWeChat/net/kvcomm',base/'Documents/xwechat/net/kvcomm']
    dirs.extend([root.parent.parent.parent/'app_data/net/kvcomm'])
    seen=set()
    for directory in dirs:
        if not directory.is_dir():continue
        for path in directory.glob('key_*.statistic'):
            m=re.match(r'key_(\d+)_',path.name)
            if not m:continue
            uin=int(m[1])
            if not 0<uin<=0xffffffff or uin in seen:continue
            seen.add(uin)
            yield hashlib.md5((str(uin)+cleaned).encode()).hexdigest()[:16].encode(),uin&255

def decode(data,key_candidates):
    if kind(data):return data
    if data.startswith(MAGIC):
        for key,xor in key_candidates:
            try:return decode_v2(data,key,xor)
            except ValueError:continue
        raise ValueError('v2_key_unavailable')
    # Legacy uniform XOR images; validate the decoded header before accepting.
    for magic in [b'\xff\xd8\xff',b'\x89PNG\r\n\x1a\n',b'GIF89a']:
        if len(data)<len(magic):continue
        xor=data[0]^magic[0]
        if bytes(x^xor for x in data[:len(magic)])==magic:
            return bytes(x^xor for x in data)
    raise ValueError('unsupported_format')

def locate(root,chat,stamp,body,packed):
    """Only hashes explicitly carried by this row, under this conversation's directories."""
    hashes=[]
    for h in re.findall(rb'(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])',packed):
        if h.lower() not in hashes:hashes.append(h.lower())
    for h in re.findall(rb'\b(?:md5|originsourcemd5)=["\']([0-9a-fA-F]{32})["\']',body):
        if h.lower() not in hashes:hashes.append(h.lower())
    if not hashes:return None
    group=hashlib.md5(chat.encode()).hexdigest();base=root.parent
    attach=base/'msg/attach'/group
    dirs=sorted(attach.glob('*/Img')) if attach.is_dir() else []
    dirs+=sorted((base/'cache').glob('*/Message/'+group+'/Bubble'))
    variants=['.dat','_h.dat','_h_M.dat','_t.dat','_t_M.dat','_b.dat','_w.dat','_c.dat','.jpg','.png']
    for h in hashes:
        for suffix in variants:
            for directory in dirs:
                path=directory/(h.decode()+suffix)
                if path.is_file() and path.resolve().is_relative_to(base.resolve()):return str(path)
    return None

def perform(q):
    root=Path(q['root']).resolve(strict=True);base=root.parent
    chat=q['chat'];group=hashlib.md5(chat.encode()).hexdigest();keys=list(candidates(root));out=[];remaining=int(q.get('inputBudget',80*1024*1024))
    for raw in q['paths']:
        result={'path':raw,'status':'missing'}
        try:
            path=Path(raw).resolve(strict=True)
            allowed=path.is_relative_to(base/'msg/attach'/group) or any(path.is_relative_to(p) for p in (base/'cache').glob('*/Message/'+group+'/Bubble'))
            if not allowed:raise ValueError('outside_conversation')
            size=path.stat().st_size
            if size>MAX_FILE:raise ValueError('file_over_40mb')
            if size>remaining:raise ValueError('input_budget')
            remaining-=size
            data=decode(path.read_bytes(),keys)
            thumbnail='_t' in path.stem or '/Bubble/' in str(path)
            if kind(data)=='wxgf':
                stem=re.sub(r'_(?:h|t|b|w|c)(?:_M)?$','',path.stem)
                for suffix in ['_t.dat','_t_M.dat','_b.dat']:
                    fallback=path.with_name(stem+suffix)
                    if fallback.is_file() and fallback.resolve().is_relative_to(path.parent.resolve()) and fallback.stat().st_size<=min(MAX_FILE,remaining):
                        remaining-=fallback.stat().st_size
                        try:
                            candidate=decode(fallback.read_bytes(),keys)
                            if kind(candidate)!='wxgf':data=candidate;thumbnail=True;break
                        except ValueError:continue
                if kind(data)=='wxgf':raise ValueError('wxgf_requires_decoder')
            result.update(status='decoded_thumbnail' if thumbnail else 'decoded',data=base64.b64encode(data).decode())
        except (OSError,ValueError) as e:
            code=str(e);result['status']=code if code in {'v2_key_unavailable','unsupported_format','wxgf_requires_decoder','file_over_40mb','input_budget','outside_conversation'} else 'missing_or_invalid'
        out.append(result)
    return {'images':out}

if __name__=='__main__':
    try:print(json.dumps(perform(json.load(sys.stdin))))
    except Exception:print(json.dumps({'images':[],'error':'image_read_failed'}))
