local json = require("json")

local function Escape(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Only the fixed loopback service is allowed, never a URL from an API response.
local Bridge = Class(function(self, inst, connection)
    self.inst = inst
    self.pending = {}
    self.closed = false
    if type(connection) == "table" and connection.host == "127.0.0.1"
        and connection.port == 17863 and type(connection.token) == "string"
        and #connection.token >= 16 and #connection.token <= 256
        and connection.token:match("^[%w_-]+$") then
        self.base = "http://127.0.0.1:17863"
        self.token = connection.token
    end
end)

function Bridge:IsConfigured() return self.base ~= nil end

local SLOW_GET = {
    ["/api/discover"]=true, ["/api/search"]=true, ["/api/playlists"]=true,
    ["/api/playlist"]=true, ["/api/lyrics"]=true, ["/api/lyric-glyphs"]=true,
    ["/api/artwork"]=true, ["/api/login/artwork"]=true, ["/api/login/check"]=true,
}
local function ValidID(id)
    return type(id)=="string" and #id==32 and id:match("^[%da-fA-F]+$")~=nil
end

function Bridge:CancelPending()
    for req in pairs(self.pending) do req.cancel() end
    self.pending = {}
end

function Bridge:Close()
    if self.closed then return end
    self.closed = true
    self:CancelPending()
    self.inst, self.token = nil, nil
end

function Bridge:Request(path, method, body, callback)
    if self.closed then return end
    if not self:IsConfigured() then
        if callback then callback(nil, "请先双击模组目录的「一键启动播放器.cmd」，然后点击重新连接") end
        return
    end
    method = method or "GET"
    local endpoint = path:match("^[^?]+")
    local slow = method=="GET" and SLOW_GET[endpoint] or method=="POST" and
        (endpoint=="/api/login/start" or endpoint=="/api/updates/check" or endpoint=="/api/control" and type(body)=="table" and
        (body.action=="play" or body.action=="next" or body.action=="previous"))
    local req = { callback = callback }
    self.pending[req] = true
    local pending, inst = self.pending, self.inst
    local base, token = self.base, Escape(self.token)
    local function URL(p)
        return base..p..(p:find("?",1,true) and "&" or "?").."token="..token
    end
    local function CancelJob(id)
        if not ValidID(id) then return end
        pcall(function()
            TheSim:QueryServer(URL("/api/request/cancel"), function() end, "POST", json.encode({requestId=id}))
        end)
    end
    local function Cleanup(cancelJob)
        pending[req]=nil
        if req.timeout then req.timeout:Cancel(); req.timeout=nil end
        if req.poll then req.poll:Cancel(); req.poll=nil end
        if cancelJob and req.job then CancelJob(req.job) end
        req.job=nil
    end
    req.cancel=function()
        if req.done then return end
        req.done=true; req.callback=nil; Cleanup(true)
    end
    local function Finish(data, err, cancelJob)
        if req.done then return end
        req.done=true
        local cb=req.callback; req.callback=nil
        Cleanup(cancelJob)
        if cb then cb(data,err) end
    end
    local function Deliver(value, successful, code)
        if type(value)=="table" and value.ok==false then
            Finish(nil,type(value.error)=="string" and value.error or "本机播放器拒绝了请求",true)
        elseif not successful or code~=200 then
            Finish(nil,"无法连接本机播放器，请检查后台是否运行",true)
        elseif type(value)~="table" or value.ok~=true then
            Finish(nil,"本机播放器响应格式错误",true)
        else
            Finish(value,nil,false)
        end
    end
    req.timeout=inst:DoStaticTaskInTime(slow and 45 or 8,function()
        Finish(nil,"连接超时，请检查本机播放器；操作可能已生效，请刷新状态",true)
    end)
    local Poll
    local function SchedulePoll()
        req.poll=inst:DoStaticTaskInTime(.5,function()
            req.poll=nil
            if not req.done then Poll() end
        end)
    end
    local function Process(result,successful,code,isPoll)
        local decoded,value=pcall(json.decode,result or "")
        if not decoded then value=nil end
        if req.done then
            -- QueryServer itself is not cancellable: a late initial pending
            -- response can reveal a job only after its owner was closed.
            if not isPoll and type(value)=="table" and value.pending==true then CancelJob(value.requestId) end
            return
        end
        if not successful or code~=200 or type(value)~="table" or value.ok~=true then
            Deliver(value,successful,code); return
        end
        if value.pending==true then
            local id=value.requestId
            if not slow or not ValidID(id) or req.job and req.job~=id then
                Finish(nil,"本机播放器响应格式错误",true); return
            end
            req.job=id
            SchedulePoll()
        elseif isPoll then
            if value.pending~=false or type(value.response)~="table" or type(value.status)~="number" then
                Finish(nil,"本机播放器响应格式错误",true); return
            end
            Deliver(value.response,true,value.status)
        else
            Deliver(value,true,code)
        end
    end
    Poll=function()
        local ok=pcall(function()
            TheSim:QueryServer(URL("/api/request/result?id="..Escape(req.job)),function(result,successful,code)
                Process(result,successful,code,true)
            end,"GET")
        end)
        if not ok then Finish(nil,"游戏未能发起本机请求，请检查客户端日志（勿公开凭据）",true) end
    end
    if slow then path=path..(path:find("?",1,true) and "&" or "?").."gameAsync=1" end
    -- DST's json.encode({}) emits []; our POST endpoints expect objects.
    local empty=type(body)=="table" and next(body)==nil
    local encoded=empty and "{}" or (body and json.encode(body) or nil)
    local ok=pcall(function()
        TheSim:QueryServer(URL(path),function(result,successful,code) Process(result,successful,code,false) end,method,encoded)
    end)
    if not ok then Finish(nil,"游戏未能发起本机请求，请检查客户端日志（勿公开凭据）",true) end
end

Bridge.Escape = Escape
return Bridge
