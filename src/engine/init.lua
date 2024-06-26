local love = love
local lg = love.graphics

local OrderedSet = require "util.orderedSet"
local StrongType = require "lang.strongType"
local hexToUID = require "util.hexToUid"
local Project = require "project"
local fontCache = require "util.fontCache"

---@alias ObjectType "object" | "sprite" | "text"

---@class Script: Resource
---@field code string
---@field compiledCode {code: string, func: function, sourceMap: table<number, number>, events: table<string, fun(instance: StrongTypeInstance, ...: any)>}?

---@class SpriteData: Resource
---@field w number
---@field h number
---@field frames SpriteFrame[] A list of all the frames in this sprite. They are all assumed to be the same size.

---@class SpriteFrame
---@field imageData love.ImageData
---@field image love.Image

---@class Object
---@field type ObjectType
---@field visible boolean
---@field x number
---@field y number
---@field script? Script
---@field scriptInstance StrongTypeInstance?

---@class Sprite: Object
---@field spriteData SpriteData

---@class Text: Object
---@field text love.Text
---@field string string
---@field fontSize number
---@field font love.Font

---@class Scene: Resource
---@field objects Object[]

local objectType = StrongType.new("Object", {
  x = { type = "number" },
  y = { type = "number" },
})

local spriteType = StrongType.new("Sprite", {}, objectType)

local textType = StrongType.new("Text", {
  text = {
    type = "string",

    ---@param self Text
    ---@return string
    getter = function(self)
      return self.string
    end,

    ---@param self Text
    ---@param value string
    setter = function(self, value)
      self.string = value
      self.text:set(value)
    end
  },
  fontSize = { type = "number" }
}, objectType)

local objectStrongTypes = {
  object = objectType,
  sprite = spriteType,
  text = textType,
}

-- the maximum amount of times to `yield` inside a loop before moving on.
local maxLoopYields = 1000

-- How many seconds to wait while `stuckInLoop` before showing it to the user.
local loopStuckWaitDuration = 3

---Returns a copy of an object.
---@param o Object
---@return Object
local function copyObject(o)
  ---@type Object
  local new = {
    type = o.type,
    visible = o.visible,
    x = o.x,
    y = o.y,
    script = o.script
  }
  if o.type == "sprite" then
    ---@cast o Sprite
    ---@cast new Sprite
    new.spriteData = o.spriteData
  elseif o.type == "text" then
    ---@cast o Text
    ---@cast new Text
    new.string = o.string
    new.fontSize = o.fontSize
    new.font = o.font
  end
  return new
end

-- An instance of a running Makeshift engine.<br>
-- Used in the editor and the runtime.
---@class Engine
---@field objects OrderedSet
local Engine = {}
Engine.__index = Engine

---@param scene Scene?
---@param active boolean?
function Engine:init(scene, active)
  if active then
    self.running = true

    --Stores events that were emitted while the game stalled, to be executed once the game gets running again.
    self.pendingEvents = {}

    self.scriptEnvironment = self:createEnvironment()

    --Counts the number of times a specific loop iterated in a single update.
    ---@type table<string, number>
    self.loopCounts = {}

    -- This coroutine is responsible for running user code, which yields in loops.
    -- This is needed in order to give back control to makeshift in case user code
    -- runs in a loop and doesn't exit from it.
    self.codeRunner = coroutine.create(function(...)
      while true do
        ---@type Object, string, any, any, any, any
        local object, event, p1, p2, p3, p4 = coroutine.yield("eventEnd")
        local f = object.script.compiledCode.events[event]
        if f then
          f(object.scriptInstance, p1, p2, p3, p4)
        end
      end
    end)
    coroutine.resume(self.codeRunner)
  end

  self.objects = OrderedSet.new()
  if scene then
    for _, obj in ipairs(scene.objects) do
      local newObj = copyObject(obj)
      if active and obj.script and obj.script.compiledCode then
        for _, f in pairs(obj.script.compiledCode.events) do
          setfenv(f, self.scriptEnvironment)
        end
        newObj.scriptInstance = objectStrongTypes[obj.type]:instance(newObj)
      end
      self:addObject(newObj)
    end
  end
end

---Prepares an Object with any runtime objects that it needs, that weren't loaded from the file (such as images and Text objects.)<br>
---Returns the same object for convenience.
---@param obj Object
---@return Object
function Engine:prepareObjectRuntime(obj)
  obj.visible = true -- TODO temporary before this property is serialized in the project
  if obj.type == "sprite" then
    ---@cast obj Sprite
    self:prepareResourceRuntime(obj.spriteData)
  elseif obj.type == "text" then
    ---@cast obj Text
    if not obj.font then
      obj.font = fontCache.get("Inter-Regular.ttf", obj.fontSize)
    end
    obj.text = love.graphics.newText(obj.font, obj.string)
  end
  return obj
end

---Prepares a resource with any runtime objects that it needs, that weren't loaded from the file (such as images and Text objects.)
---@param r Resource
function Engine:prepareResourceRuntime(r)
  if r.type == "scene" then
    ---@cast r Scene
    for _, o in ipairs(r.objects) do
      self:prepareObjectRuntime(o)
    end
  elseif r.type == "spriteData" then
    ---@cast r SpriteData
    for _, f in ipairs(r.frames) do
      if not f.image then
        f.image = love.graphics.newImage(f.imageData)
        f.image:setFilter("linear", "nearest")
      end
    end
  end
end

---Decodes the error message string to figure out which script and on which line the error occured,
---and opens the code editor for that script.
---@param fullMessage string
function Engine:handleError(fullMessage)
  local source, line, message = fullMessage:match('%[string "(.*)"%]:(%d*): (.*)')
  self.errorSource = hexToUID(source)
  local script = Project.currentProject:getResourceById(self.errorSource)
  if not script then
    return
  end
  ---@cast script Script
  self.errorScript = script
  local actualLine
  local sourceMap = script.compiledCode.sourceMap
  for i = tonumber(line), 1, -1 do
    if sourceMap[i] then
      actualLine = sourceMap[i]
      break
    end
  end
  self.errorMessage = message
  self.errorLine = actualLine
  self:openErroredCodeEditor()
end

---Opens the resource editor for the script where the current error happened.
function Engine:openErroredCodeEditor()
  local editor = OpenResourceTab(self.errorScript) --[[@as CodeEditor]]
  editor:showError()
end

---Figures out the Script and line which the code is currently suck on.
function Engine:parseLoopStuckCode()
  local maxStuckLoop
  local maxStuckLoopCount
  for k, v in pairs(self.loopCounts) do
    if not maxStuckLoopCount or v > maxStuckLoopCount then
      maxStuckLoop = k
      maxStuckLoopCount = v
    end
  end
  local id, startLine, endLine = maxStuckLoop:match("loop (%w+) (%d+) (%d+)")
  self.loopStuckScript = Project.currentProject:getResourceById(hexToUID(id)) --[[@as Script]]
  self.loopStuckStartLine = tonumber(startLine)
  self.loopStuckEndLine = tonumber(endLine)
end

function Engine:createEnvironment()
  return {
    _yield = coroutine.yield,
    keyDown = function(key)
      local success, result = pcall(love.keyboard.isDown, key)
      if not success then
        error(("%q is not a valid key"):format(key), 2)
      end
      return result
    end
  }
end

-- Runs the event runner either until it finishes the current event, or
-- it runs a loop for more than a specified amount.
--
-- If parameters are given, it starts the runner with those parameters.
---@param object Object
---@param event string
---@param p1 any
---@param p2 any
---@param p3 any
---@param p4 any
---@overload fun()
function Engine:tryContinueRunner(object, event, p1, p2, p3, p4)
  local stillInLoop = true

  -- whether the initial call to `resume` was already done for this event
  local ranInitial = not object

  for _ = 1, maxLoopYields do
    local success, result
    if not ranInitial then
      ranInitial = true
      success, result = coroutine.resume(self.codeRunner, object, event, p1, p2, p3, p4)
    else
      success, result = coroutine.resume(self.codeRunner)
    end
    ---@cast result string
    if success then
      if result:find("endloop") then
        self.loopCounts[result:match("loop.+")] = nil
      elseif result:find("loop") then
        self.loopCounts[result] = (self.loopCounts[result] or 0) + 1
      elseif result == "eventEnd" then
        stillInLoop = false
        break
      else
        error("unknown coroutine result? " .. result)
      end
    else
      self.running = false
      self:handleError(result)
      break
    end
  end

  if stillInLoop then
    self.loopStuckTime = self.loopStuckTime or love.timer.getTime()
    self.stuckInLoop = true
  else
    self.loopStuckTime = nil
    self.stuckInLoop = false
    while next(self.loopCounts) do
      self.loopCounts[next(self.loopCounts)] = nil
    end
    self.loopStuckScript = nil
    self.loopStuckStartLine = nil
  end
end

-- starts executing an object's method. it may finish running in the same call,
-- but it may also enter a stuck loop from here.
---@param object Object
---@param event string
---@param p1 any
---@param p2 any
---@param p3 any
---@param p4 any
function Engine:callObjectEvent(object, event, p1, p2, p3, p4)
  if not self.running then
    return
  end

  if not object.script or not object.script.compiledCode or not object.script.compiledCode.events[event] then
    return
  end

  if self.stuckInLoop then
    -- insert this event to be executed later, after the code exits the stuck loop
    table.insert(self.pendingEvents, { object, event, p1, p2, p3, p4 })
    return
  end

  self:tryContinueRunner(object, event, p1, p2, p3, p4)
end

---Add an object into the scene.
---@param obj Object
function Engine:addObject(obj)
  self:prepareObjectRuntime(obj)
  self.objects:add(obj)
end

---Returns the bounding box that this Object occupies.
---@param object Object
---@return number, number, number, number
function Engine:getObjectBoundingBox(object)
  if object.type == "text" then
    ---@cast object Text
    local w, h = object.text:getDimensions()
    if object.string:sub(#object.string) == "\n" then
      h = h + object.font:getHeight()
    end
    w = math.max(w, object.font:getWidth(" "))
    h = math.max(h, object.font:getHeight())
    return object.x, object.y, w, h
  elseif object.type == "sprite" then
    ---@cast object Sprite
    return object.x, object.y, object.spriteData.w, object.spriteData.h
  end
  return object.x - 3, object.y - 3, object.x + 3, object.y + 3
end

local tempTransform = love.math.newTransform()
---Returns the transform needed to display this object at its correct position.
---@param object Object
---@return love.Transform
function Engine:getObjectTransform(object)
  return tempTransform:setTransformation(object.x, object.y)
end

function Engine:update(dt)
  if not self.running then return end

  -- if the code is currently stuck in a loop, we only focus on trying to
  -- complete it (one batch of tries every frame), and only run updates after it's finished
  if self.stuckInLoop then
    self:tryContinueRunner()
  end

  while not self.stuckInLoop and #self.pendingEvents > 0 do
    self:callObjectEvent(unpack(table.remove(self.pendingEvents, 1)))
  end

  if not self.stuckInLoop then
    -- finally, if we're not stuck in a loop anymore, run the update event for all objects.
    for _, object in ipairs(self.objects.list) do
      -- TODO decide whether to include deltatime or not
      self:callObjectEvent(object, "update")
    end
  end

  if self.stuckInLoop and not self.loopStuckScript and love.timer.getTime() > self.loopStuckTime + loopStuckWaitDuration then
    self:parseLoopStuckCode()
  end
end

function Engine:draw()
  for _, o in ipairs(self.objects.list) do
    ---@cast o Object
    if o.visible then
      lg.push()
      lg.applyTransform(self:getObjectTransform(o))
      if o.type == "sprite" then
        ---@cast o Sprite
        lg.setColor(1, 1, 1)
        lg.draw(o.spriteData.frames[1].image)
      elseif o.type == "text" then
        ---@cast o Text
        lg.setColor(1, 1, 1)
        lg.draw(o.text)
      end
      lg.pop()
    end
  end
end

---Creates a new Engine.
---@param scene Scene?
---@param active boolean?
---@return Engine
local function createEngine(scene, active)
  local self = setmetatable({}, Engine)
  self:init(scene, active)
  return self
end

return {
  createEngine = createEngine
}
