local love = love
local lg = love.graphics

local zap = require "lib.zap.zap"
local Slider = require "ui.components.colorPicker.slider"
local hsvToRgb = require "util.hsvToRgb"
local rgbToHsv = require "util.rgbToHsv"
local FontCache = require "util.fontCache"
local DragInput = require "ui.components.dragInput"
local viewTools = require "util.viewTools"

local labelFont = FontCache.get("Inter-Regular.ttf", 14)

local slidersHSV = {
  {
    label = "H",
    minValue = 0,
    maxValue = 360,
  },
  {
    label = "S",
    minValue = 0,
    maxValue = 100,
  },
  {
    label = "V",
    minValue = 0,
    maxValue = 100,
  },
}

---@class ColorPicker: Zap.ElementClass
---@field color number[]
---@field sliders ColorPicker.Slider[]
---@field dragInputs DragInput[]
---@operator call:ColorPicker
local ColorPicker = zap.elementClass()

function ColorPicker:init(color)
  self.color = color
  self.modeledColor = { rgbToHsv(unpack(color)) }

  self.sliders = {}
  self.dragInputs = {}
  for i = 1, 3 do
    local sliderInfo = slidersHSV[i]
    local theSlider = Slider()
    theSlider.model = self.modeledColor
    theSlider.modelKey = i
    theSlider.minValue = sliderInfo.minValue
    theSlider.maxValue = sliderInfo.maxValue
    theSlider.colorFunc = hsvToRgb
    table.insert(self.sliders, theSlider)
    theSlider.onChange = function()
      self:updateColor(theSlider.modelKey)
    end
    theSlider:updateImage()

    local theDragInput = DragInput()
    theDragInput.targetObject = self.modeledColor
    theDragInput.targetKey = i
    theDragInput.onChange = function()
      self:updateColor()
    end
    theDragInput.minValue = sliderInfo.minValue
    theDragInput.maxValue = sliderInfo.maxValue
    theDragInput.font = labelFont
    table.insert(self.dragInputs, theDragInput)
  end
end

---Updates the color picker's color based on the modeled color, and update all the sliders' images.
---@param excludeSlider? number Optionally skip updating the slider at this index.
function ColorPicker:updateColor(excludeSlider)
  self.color[1], self.color[2], self.color[3], self.color[4] = hsvToRgb(unpack(self.modeledColor))
  for j, s in ipairs(self.sliders) do
    if j ~= excludeSlider then
      s:updateImage()
    end
  end
end

function ColorPicker:render(x, y, w, h)
  lg.setColor(CurrentTheme.backgroundActive)
  lg.rectangle("fill", x, y, w, h, 6)

  x, y, w, h = viewTools.padding(x, y, w, h, 6)

  local sliderHeight = math.floor(h / #self.sliders)
  for i, s in ipairs(self.sliders) do
    local sliderY = math.floor(y + sliderHeight * (i - 1))
    local textY = math.floor(sliderY + sliderHeight / 2 - labelFont:getHeight() / 2)
    lg.setColor(CurrentTheme.foregroundActive)
    lg.setFont(labelFont)
    lg.print(slidersHSV[i].label, x, textY)

    local leftLabelWidth = labelFont:getWidth("H ")
    local rightLabelWidth = labelFont:getWidth("9999") + 3
    self.dragInputs[i]:render(x + w - rightLabelWidth, sliderY, rightLabelWidth, sliderHeight)
    s:render(x + leftLabelWidth, sliderY, w - leftLabelWidth - rightLabelWidth, sliderHeight)
  end
end

return ColorPicker
