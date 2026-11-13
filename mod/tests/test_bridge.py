"""Offline bridge contract only; does not simulate DST UI or real HTTP.

python mod/tests/test_bridge.py --scripts-zip ".../databundles/scripts.zip"
Requires lupa (Lua 5.1) and the user's installed DST scripts for Class/JSON.
"""
import argparse
from pathlib import Path
from zipfile import ZipFile
from lupa.lua51 import LuaRuntime

parser = argparse.ArgumentParser()
parser.add_argument("--scripts-zip", required=True)
args = parser.parse_args()
lua = LuaRuntime(unpack_returned_tuples=True)
with ZipFile(args.scripts_zip) as archive:
    lua.execute(archive.read("scripts/class.lua").decode("utf-8-sig"))
    lua.execute("package.preload.json = function()\n" +
                archive.read("scripts/json.lua").decode("utf-8-sig") + "\nend")
lua.globals().Bridge = lua.execute(
    (Path(__file__).resolve().parents[1] / "scripts/dangomusic_bridge.lua").read_text(encoding="utf-8"))
lua.execute(r'''
local tasks, requests = {}, {}
local inst = {DoTaskInTime = function(_, seconds, fn)
    local task = {seconds=seconds,fn=fn, Cancel=function(self) self.cancelled=true end}
    tasks[#tasks+1] = task
    return task
end}
TheSim = {QueryServer=function(_, url, fn, method, body)
    requests[#requests+1] = {url=url, fn=fn, method=method, body=body}
end}
local bridge = Bridge(inst, {host='127.0.0.1', port=17863, token=string.rep('a',32)})
assert(bridge:IsConfigured())
local calls, lastdata, lasterror = 0
local function callback(data, err) calls=calls+1; lastdata=data; lasterror=err end
bridge:Request('/api/status', 'GET', nil, callback)
assert(tasks[1].seconds==8)
assert(requests[1].url:match('^http://127%.0%.0%.1:17863/api/status%?token='))
requests[1].fn('{"ok":true,"revision":3}', true, 200)
assert(calls==1 and lastdata.revision==3 and lasterror==nil and tasks[1].cancelled)
requests[1].fn('{"ok":true}', true, 200)
assert(calls==1, 'duplicate callback must be ignored')

bridge:Request('/api/control', 'POST', {action='volume',value=.3}, callback)
assert(requests[2].method=='POST' and require('json').decode(requests[2].body).value==.3)
tasks[2].fn()
assert(calls==2 and lasterror and next(bridge.pending)==nil)
requests[2].fn('{"ok":true}',true,200)
assert(calls==2, 'late callback after timeout must be ignored')

bridge:Request('/api/playlists', 'GET', nil, callback)
local req = next(bridge.pending)
bridge:CancelPending()
assert(req.callback==nil and tasks[3].cancelled and next(bridge.pending)==nil)
requests[3].fn('{"ok":true}',true,200)
assert(calls==2, 'inactive UI must not receive callbacks')
bridge:Request('/api/status', 'GET', nil, callback)
requests[4].fn('{"ok":false,"error":"denied"}',true,403)
assert(calls==3 and lasterror=='denied', 'reactivation and readable API error')
bridge:Request('/api/status', 'GET', nil, callback)
req = next(bridge.pending)
bridge:Close(); bridge:Close()
assert(req.callback==nil and bridge.token==nil and bridge.inst==nil and tasks[5].cancelled)
requests[5].fn('{"ok":true}',true,200)
assert(calls==3)
bridge:Request('/api/status','GET',nil,callback)
assert(#requests==5 and calls==3, 'closed bridge must stay closed')
local bad = Bridge(inst,{host='example.com',port=17863,token=string.rep('a',32)})
bad:Request('/api/status','GET',nil,callback)
assert(not bad:IsConfigured() and calls==4 and lasterror:find('一键启动播放器.cmd',1,true) and not lasterror:find('重启游戏',1,true) and #requests==5)
assert(Bridge.Escape('1&x=2')=='1%26x%3D2')
local empty = Bridge(inst,{host='127.0.0.1',port=17863,token=string.rep('a',32)})
empty:Request('/api/login/start','POST',{},function() end)
assert(tasks[6].seconds==45, 'login start must allow 45 seconds')
assert(requests[6].body=='{}', 'empty login payload must be JSON object, not DST empty array')
requests[6].fn('{"ok":true}',true,200)
empty:Request('/api/logout','POST',{},function() end)
assert(tasks[7].seconds==8, 'other requests must retain the 8 second timeout')
assert(requests[7].body=='{}', 'empty logout payload must be JSON object')
empty:Close()
''')
lua.execute(r'''
local tasks,requests={},{}
local inst={DoTaskInTime=function(_,seconds,fn)
 local t={seconds=seconds,fn=fn,Cancel=function(self) self.cancelled=true end}
 tasks[#tasks+1]=t;return t
end}
TheSim={QueryServer=function(_,url,fn,method,body)
 requests[#requests+1]={url=url,fn=fn,method=method,body=body}
end}
local bridge=Bridge(inst,{host='127.0.0.1',port=17863,token=string.rep('a',32)})
local id=string.rep('a',32);local id2=string.rep('b',32)
local calls,data,err=0,nil,nil
local function cb(d,e) calls=calls+1;data=d;err=e end
local function reply(req,value,status) req.fn(require('json').encode(value),true,status or 200) end
local function start(path,method,body)
 bridge:Request(path,method,body,cb);return requests[#requests],tasks[#tasks]
end
local initial,deadline=start('/api/search?q=x','GET')
assert(initial.url:find('gameAsync=1',1,true) and deadline.seconds==45)
reply(initial,{ok=true,tracks={}});assert(calls==1 and data.ok and deadline.cancelled)
initial,deadline=start('/api/playlists','GET')
reply(initial,{ok=true,pending=true,requestId=id})
local scheduled=tasks[#tasks];assert(scheduled.seconds==.5 and not deadline.cancelled)
scheduled.fn();local poll=requests[#requests]
assert(poll.url:find('/api/request/result?id='..id,1,true) and not poll.url:find('gameAsync=1',1,true))
reply(poll,{ok=true,pending=true,requestId=id});tasks[#tasks].fn();poll=requests[#requests]
reply(poll,{ok=true,pending=false,response={ok=true,playlists={{id='x'}}},status=200})
assert(calls==2 and data.playlists[1].id=='x' and deadline.cancelled)
poll.fn('{}',true,200);assert(calls==2,'duplicate result must not invoke callback')
initial,deadline=start('/api/login/start','POST',{provider='qq'})
reply(initial,{ok=true,pending=true,requestId=id});tasks[#tasks].fn();poll=requests[#requests]
reply(poll,{ok=true,pending=false,response={ok=false,error='登录失败'},status=401})
assert(calls==3 and err=='登录失败' and deadline.cancelled)
initial,deadline=start('/api/playlist?id=1','GET');reply(initial,{ok=true,pending=true,requestId=id})
scheduled=tasks[#tasks];bridge:CancelPending()
assert(scheduled.cancelled and deadline.cancelled and next(bridge.pending)==nil)
local cancel=requests[#requests];assert(cancel.url:find('/api/request/cancel?',1,true) and require('json').decode(cancel.body).requestId==id)
scheduled.fn();assert(calls==3)
initial,deadline=start('/api/artwork?trackId=1','GET');reply(initial,{ok=true,pending=true,requestId=id})
local before=#requests;deadline.fn()
assert(calls==4 and err and #requests==before+1 and requests[#requests].url:find('/api/request/cancel?',1,true))
initial,deadline=start('/api/discover?section=charts','GET');deadline.fn()
local afterTimeout=calls;local beforeLate=#requests
reply(initial,{ok=true,pending=true,requestId=id})
assert(calls==afterTimeout and #requests==beforeLate+1 and require('json').decode(requests[#requests].body).requestId==id,'late start must cancel its job')
initial,deadline=start('/api/search?q=x','GET');reply(initial,{ok=true,pending=true,requestId=id});tasks[#tasks].fn();poll=requests[#requests]
reply(poll,{ok=true,pending=true,requestId=id2})
assert(calls==afterTimeout+1 and err=='本机播放器响应格式错误' and require('json').decode(requests[#requests].body).requestId==id)
initial,deadline=start('/api/lyrics?trackId=1','GET');reply(initial,{ok=true,pending=true,requestId='invalid'})
assert(calls==afterTimeout+2 and err=='本机播放器响应格式错误')
for _,path in ipairs({'/api/discover','/api/search','/api/playlists','/api/playlist','/api/lyrics',
 '/api/lyric-glyphs','/api/artwork','/api/login/artwork','/api/login/check'}) do
 local r,t=start(path,'GET');assert(t.seconds==45 and r.url:find('gameAsync=1',1,true),path)
 reply(r,{ok=true})
end
for _,action in ipairs({'play','next','previous'}) do
 local r,t=start('/api/control','POST',{action=action});assert(t.seconds==45 and r.url:find('gameAsync=1',1,true),action)
 reply(r,{ok=true})
end
local update,updateDeadline=start('/api/updates/check','POST',{})
assert(updateDeadline.seconds==45 and update.url:find('gameAsync=1',1,true),'version check must use receipt transport')
reply(update,{ok=true,status='unpublished'})
for _,action in ipairs({'pause','resume','toggle','seek','volume'}) do
 local r,t=start('/api/control','POST',{action=action});assert(t.seconds==8 and not r.url:find('gameAsync=1',1,true),action)
 reply(r,{ok=true})
end
local fast,fastDeadline=start('/api/control','POST',{action='volume',value=.4})
assert(fastDeadline.seconds==8 and not fast.url:find('gameAsync=1',1,true))
reply(fast,{ok=true})
local slow,slowDeadline=start('/api/control','POST',{action='next'})
assert(slowDeadline.seconds==45 and slow.url:find('gameAsync=1',1,true))
bridge:Close();local n=#requests;reply(slow,{ok=true,pending=true,requestId=id})
assert(#requests==n+1 and require('json').decode(requests[#requests].body).requestId==id,'closed bridge must cancel late job')
''')
print("PASS: bridge success, POST, timeout, stale/duplicate callback, inactive/close cleanup, fixed loopback")
