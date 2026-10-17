#!/usr/bin/env python3
"""Loopback-only synthetic SSE fixture. No credentials or request bodies are logged."""
import json,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
TEXT='''## 讨论小结

这是一段**合成测试回答**，用于检查流式输出与 Markdown，不包含真实聊天。

- 已确认：支持群聊和私聊。
- 正在验证：全屏桌面里的小气泡。
  - 收起后保留回答。

> 切换会话时，各自保留问题和回答。

| 项目 | 状态 |
| --- | --- |
| 流式输出 | 已收到片段 |
| Markdown | 标题、列表和表格 |

```swift
let message = "你好，世界"
print(message)
```

最后一段用于确认流没有被截断。END_STREAM_OK
'''
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  payload=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
  model=payload.get('model','')
  if model=='json-fallback':
   self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
   self.wfile.write(json.dumps({'choices':[{'message':{'content':TEXT},'finish_reason':'stop'}]}).encode());return
  if payload.get('stream') is not True:
   self.send_response(400);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"error":"stream required"}');return
  self.send_response(200);self.send_header('Content-Type','text/event-stream; charset=utf-8');self.send_header('Cache-Control','no-cache');self.end_headers()
  try:
   self.wfile.write(b': keepalive\n\n');self.wfile.flush()
   for i in range(0,len(TEXT),12):
    event='data: '+json.dumps({'choices':[{'delta':{'content':TEXT[i:i+12]},'finish_reason':None}]},ensure_ascii=False)+'\n\n'
    data=event.encode()
    # Deliberately split UTF-8 and SSE delimiters across network writes.
    for j in range(0,len(data),7):self.wfile.write(data[j:j+7])
    self.wfile.flush();time.sleep(.08)
    if model=='disconnect' and i>=24:return
   self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError):pass
if __name__=='__main__':
 server=ThreadingHTTPServer(('127.0.0.1',27654),Handler)
 print('Synthetic stream fixture listening on 127.0.0.1:27654',flush=True)
 server.serve_forever()
