/// Standalone LAN API documentation served by LocalShare.
const localShareApiDocsHtml = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LocalShare 局域网 API</title><style>
body{font:16px/1.6 system-ui,-apple-system,sans-serif;background:#f4f7fc;color:#18223a;margin:0}main{max-width:960px;margin:auto;padding:28px 18px 64px}h1{margin-bottom:2px}h2{margin-top:34px}p{color:#516078}code,pre{font-family:ui-monospace,monospace}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f0f4fb;padding:14px;border-radius:10px}details{background:white;border:1px solid #dce4f0;border-radius:12px;margin:10px 0;padding:12px 16px}summary{cursor:pointer;font-weight:700;overflow-wrap:anywhere}.method{color:#1757bc;margin-right:10px}.notice{background:#fff4da;padding:14px;border-radius:12px;color:#664400}button{border:0;background:#1757bc;color:white;border-radius:8px;padding:8px 12px;cursor:pointer}a{color:#1757bc}
</style></head><body><main><h1>LocalShare API</h1><p>同一局域网中的设备可通过 HTTP 调用。<a href="/">返回 LocalShare</a></p>
<p>当前服务地址：<code id="base"></code> <button id="copy">复制</button></p>
<p class="notice">接口无需登录。能够访问本服务的设备可以读取、创建、修改及删除内容，请仅在可信网络中使用。</p>
<p>JSON 请求设置 <code>Content-Type: application/json</code>。所有路径拼接在当前服务地址之后。错误通常以 JSON <code>{"error":"..."}</code> 返回；未找到的资源返回 404。</p>
<div id="docs"></div>
<script>
const base=location.origin;
document.getElementById('base').textContent=base;
document.getElementById('copy').onclick=async()=>{try{await navigator.clipboard.writeText(base);document.getElementById('copy').textContent='已复制'}catch(_){document.getElementById('copy').textContent='请手动复制'}};
const docs=[
['卡片','GET','/api/v1/cards','获取所有卡片，包括归档。可选 q 搜索正文或附件名，archived=true 或 false 筛选。返回 {"cards":[...]}。','curl "'+base+'/api/v1/cards?archived=false"'],
['卡片','GET','/api/v1/cards/{id}','获取单张卡片，返回 {"card":{...}}。','curl "'+base+'/api/v1/cards/卡片ID"'],
['卡片','POST','/api/v1/cards','创建文本卡片，JSON 请求体 text 为非空字符串；返回 201 和 card。',"curl -X POST '"+base+"/api/v1/cards' -H 'Content-Type: application/json' -d '{\"text\":\"你好\"}'"],
['卡片','PATCH','/api/v1/cards/{id}','修改 text（字符串）、pinned、archived（布尔值），均可选。归档会取消置顶，最多置顶 5 张。',"curl -X PATCH '"+base+"/api/v1/cards/卡片ID' -H 'Content-Type: application/json' -d '{\"text\":\"新内容\",\"pinned\":true}'"],
['卡片','DELETE','/api/v1/cards/{id}','删除卡片和应用内附件；下载目录里的文件保留。此操作不可撤销。',"curl -X DELETE '"+base+"/api/v1/cards/卡片ID'"],
['卡片','POST','/api/v1/cards/upload','上传附件创建卡片。使用 multipart/form-data；第一部分 metadata 为 JSON，附件必须包含 name、mimeType、size（字节），后续 file 部分按相同顺序发送。返回 {"ok":true,"cardId":"..."}。例子要求 a.txt 恰好 3 字节。',"curl -X POST '"+base+"/api/v1/cards/upload' -F 'metadata={\"text\":\"备注\",\"attachments\":[{\"name\":\"a.txt\",\"mimeType\":\"text/plain\",\"size\":3}]}' -F 'file=@a.txt'"],
['附件','GET','/files/{attachmentId}','下载附件；?view=1 请求预览。卡片的 attachments 包含 downloadUrl 和 previewUrl 相对路径。',"curl -OJ '"+base+"/files/附件ID'"],
['附件','GET','/cards/{cardId}/bundle','下载卡片所有附件的 ZIP。',"curl -OJ '"+base+"/cards/卡片ID/bundle'"],
['临时聊天','GET','/api/chat','获取临时聊天消息，返回对象中的 messages 是消息列表。',"curl '"+base+"/api/chat'"],
['临时聊天','POST','/api/chat/messages','发送文本消息。',"curl -X POST '"+base+"/api/chat/messages' -H 'Content-Type: application/json' -d '{\"text\":\"你好\",\"sender\":\"api\"}'"],
['临时聊天','POST','/api/chat/messages/upload','发送文件消息。multipart 格式同卡片上传，metadata 可包含 sender。','metadata 放在 file 之前，attachments 的顺序与 file 部分相同。'],
['临时聊天','POST','/api/chat/messages/{id}/save-card','将临时消息保存为卡片，返回 cardId。',"curl -X POST '"+base+"/api/chat/messages/消息ID/save-card'"],
['临时聊天','POST','/api/chat/messages/{id}/delete','删除临时消息及其临时附件。',"curl -X POST '"+base+"/api/chat/messages/消息ID/delete'"],
['临时聊天','POST','/api/chat/clear','清空临时聊天及其附件；不可撤销。',"curl -X POST '"+base+"/api/chat/clear'"],
['临时聊天','GET','/chat/files/{attachmentId}','下载临时聊天附件；?view=1 请求预览。',"curl -OJ '"+base+"/chat/files/附件ID'"]
];
const root=document.getElementById('docs');let group='';
for(const [section,method,path,description,example] of docs){if(section!==group){group=section;const h=document.createElement('h2');h.textContent=section;root.append(h)}const detail=document.createElement('details');const summary=document.createElement('summary');const tag=document.createElement('span');tag.className='method';tag.textContent=method;summary.append(tag,document.createTextNode(path));const p=document.createElement('p');p.textContent=description;const pre=document.createElement('pre');pre.textContent=example;detail.append(summary,p,pre);root.append(detail)}
</script></main></body></html>''';
