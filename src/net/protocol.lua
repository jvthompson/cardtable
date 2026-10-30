-- Wire protocol (port of lib/networking/net_message.dart): one JSON object
-- per line, {"type": "<name>", "payload": {...}}, over plain TCP. Kept
-- byte-compatible with the Flutter app so the two can interoperate.
--
-- Connection wraps a non-blocking luasocket TCP socket with a line reader
-- and a write buffer (large messages such as gameData go out over several
-- frames).
local socket = require("socket")
local json = require("lib.json")

local P = {}

P.defaultGamePort = 51234
-- Sent in hello so a CardTable server (server/) can answer with serverInfo;
-- peer hosts ignore it. Bump when the server protocol changes, and run
-- server/tools/sync-engine.ps1 so the server agrees.
P.serverProtocolVersion = 3
P.heartbeatInterval = 4
P.heartbeatTimeout = 12

function P.encodeLine(msgType, payload)
  return json.encode(json.object({ "type", msgType, "payload", payload or json.object() })) .. "\n"
end

-- Returns { type=, payload= } or nil for a malformed/blank line.
function P.decodeLine(line)
  if line:match("^%s*$") then return nil end
  local v = json.tryDecode(line)
  if type(v) ~= "table" or type(v.type) ~= "string" then return nil end
  local payload = v.payload
  if type(payload) ~= "table" or payload == json.null then payload = {} end
  return { type = v.type, payload = payload }
end

---------------------------------------------------------------------------
-- Connection
---------------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection
P.Connection = Connection

function P.wrap(sock)
  sock:settimeout(0)
  pcall(sock.setoption, sock, "tcp-nodelay", true)
  return setmetatable({ sock = sock, inbuf = "", out = {}, outPos = 1, closed = false }, Connection)
end

function Connection:send(msgType, payload)
  if self.closed then return end
  self.out[#self.out + 1] = P.encodeLine(msgType, payload)
  self:flush()
end

function Connection:sendRaw(line)
  if self.closed then return end
  self.out[#self.out + 1] = line
  self:flush()
end

-- Writes as much buffered output as the socket accepts right now.
function Connection:flush()
  while not self.closed and #self.out > 0 do
    local data = self.out[1]
    local sent, err, lastIndex = self.sock:send(data, self.outPos)
    if sent then
      table.remove(self.out, 1)
      self.outPos = 1
    elseif err == "timeout" then
      self.outPos = (lastIndex or (self.outPos - 1)) + 1
      return
    else
      self:close()
      return
    end
  end
end

function Connection:pendingBytes()
  local n = 0
  for i, d in ipairs(self.out) do n = n + #d - (i == 1 and (self.outPos - 1) or 0) end
  return n
end

-- Reads everything available; returns a list of decoded messages.
function Connection:poll()
  local msgs = {}
  if self.closed then return msgs end
  self:flush()
  local data, err, partial = self.sock:receive("*a")
  local chunk = data or partial
  if chunk and #chunk > 0 then self.inbuf = self.inbuf .. chunk end
  while true do
    local nl = self.inbuf:find("\n", 1, true)
    if not nl then break end
    local line = self.inbuf:sub(1, nl - 1):gsub("\r$", "")
    self.inbuf = self.inbuf:sub(nl + 1)
    local msg = P.decodeLine(line)
    if msg then msgs[#msgs + 1] = msg end
  end
  if err and err ~= "timeout" then self:close() end
  return msgs, chunk ~= nil and #chunk > 0
end

function Connection:close()
  if self.closed then return end
  self.closed = true
  pcall(self.sock.close, self.sock)
end

-- Call once a connection is live, before the first :heartbeat(now).
function Connection:startHeartbeat(now)
  self.lastActivity, self.lastPing = now, now
end

-- Call every tick after :poll(), passing whether that poll returned any
-- bytes. Returns "timeout" once the peer's gone quiet too long (caller
-- should disconnect) or "ping" once it's time to send one; nil otherwise.
function Connection:heartbeat(now, gotData)
  if gotData then self.lastActivity = now end
  if self.closed or now - self.lastActivity > P.heartbeatTimeout then
    return "timeout"
  elseif now - self.lastPing >= P.heartbeatInterval then
    self.lastPing = now
    return "ping"
  end
end

-- Sends what's buffered (best effort, briefly blocking) then closes; used
-- for a final "disconnect" message before dropping a peer.
function Connection:closeAfterFlush()
  if self.closed then return end
  self.sock:settimeout(0.5)
  for _, d in ipairs(self.out) do pcall(self.sock.send, self.sock, d) end
  self.out = {}
  self:close()
end

---------------------------------------------------------------------------
-- Non-blocking connect
---------------------------------------------------------------------------

-- Starts connecting; returns a connector with :poll() -> "pending" |
-- "connected", conn | "failed", message.
function P.connect(host, port, timeoutSeconds)
  local sock = socket.tcp()
  sock:settimeout(0)
  local ok, err = sock:connect(host, port)
  local started = love.timer.getTime()
  local done, failure
  if ok then done = true
  elseif err ~= "timeout" and err ~= "Operation already in progress" then failure = err end
  local c = {}
  function c.poll()
    if failure then
      pcall(sock.close, sock)
      return "failed", failure
    end
    if not done then
      local _, writable = socket.select(nil, { sock }, 0)
      if writable and #writable > 0 then
        local ok2, err2 = sock:connect(host, port)
        if ok2 or err2 == "already connected" then
          done = true
        elseif err2 ~= "timeout" and err2 ~= "Operation already in progress" then
          failure = err2
          pcall(sock.close, sock)
          return "failed", failure
        end
      end
      if not done and love.timer.getTime() - started > (timeoutSeconds or 5) then
        failure = "Connection timed out"
        pcall(sock.close, sock)
        return "failed", failure
      end
      if not done then return "pending" end
    end
    return "connected", P.wrap(sock)
  end
  return c
end

---------------------------------------------------------------------------
-- Background loop: objects registered here get update(dt) every frame from
-- the app shell, regardless of which screen is showing.
---------------------------------------------------------------------------

local loop = {}

function P.register(obj) loop[obj] = true end
function P.unregister(obj) loop[obj] = nil end

function P.updateAll(dt)
  for obj in pairs(loop) do obj:update(dt) end
end

function P.stopAll()
  for obj in pairs(loop) do
    if obj.stop then pcall(obj.stop, obj) end
  end
  loop = {}
end

return P
