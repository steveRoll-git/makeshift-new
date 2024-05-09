local love = love
local lg = love.graphics

local zap = require "lib.zap.zap"
local hexToColor = require "util.hexToColor"
local images = require "images"
local fonts = require "fonts"
local viewTools = require "util.viewTools"
local dragInput = require "ui.dragInput"

local icon = images["icons/object_14.png"]

local font = fonts("Inter-Regular.ttf", 14)

---@class SceneEditorPropertiesPanel: Zap.ElementClass
---@field selectedObject Object?
---@operator call:SceneEditorPropertiesPanel
local propertiesPanel = zap.elementClass()

function propertiesPanel:init()
  self.xInput = dragInput()
  self.xInput.font = font
  self.xInput.targetKey = "x"
  self.yInput = dragInput()
  self.yInput.font = font
  self.yInput.targetKey = "y"
end

---@param obj Object
function propertiesPanel:setObject(obj)
  self.selectedObject = obj
  self.xInput.targetObject = obj
  self.yInput.targetObject = obj
end

function propertiesPanel:render(x, y, w, h)
  lg.setColor(hexToColor(0x2b2b2b))
  lg.rectangle("fill", x, y, w, h, 4)

  x, y, w, h = viewTools.padding(x, y, w, h, 7)
  lg.setColor(1, 1, 1)
  lg.draw(icon, x, math.floor(y + font:getHeight() / 2 - icon:getHeight() / 2))
  lg.setFont(font)
  lg.print("Properties", x + icon:getWidth() + 2, y)

  local inputHeightPadding = 2
  local inputLabelMargin = 4
  local separateInputMargin = 6
  local inputWidth = font:getWidth("-4444.4")
  local totalColumnWidth = inputWidth * 2 +
      font:getWidth("X") +
      font:getWidth("Y") +
      inputLabelMargin * 2 +
      separateInputMargin

  y = y + font:getHeight() + 6
  lg.print("Position", x, y)

  local cx = x + w - totalColumnWidth
  lg.print("X", cx, y)
  cx = cx + font:getWidth("X") + inputLabelMargin
  self.xInput:render(cx, y - inputHeightPadding, inputWidth, font:getHeight() + inputHeightPadding * 2)

  cx = cx + inputWidth + separateInputMargin
  lg.print("Y", cx, y)
  cx = cx + font:getWidth("Y") + inputLabelMargin
  self.yInput:render(cx, y - inputHeightPadding, inputWidth, font:getHeight() + inputHeightPadding * 2)
end

return propertiesPanel
