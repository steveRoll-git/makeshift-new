local love = love
local lg = love.graphics

local zap = require "lib.zap.zap"
local engine = require "engine"
local Toolbar = require "ui.components.toolbar"
local images = require "images"
local SpriteEditor = require "ui.editors.spriteEditor"
local ZoomSlider = require "ui.components.zoomSlider"
local PopupMenu = require "ui.components.popupMenu"
local pushScissor = require "util.scissorStack".pushScissor
local popScissor = require "util.scissorStack".popScissor
local Project = require "project"
local TextEditor = require "ui.components.textEditor"
local DataPanel = require "ui.components.dataPanel"

local zoomValues = { 0.25, 1 / 3, 0.5, 1, 2, 3, 4, 5, 6, 8, 12, 16, 24, 32, 48, 64 }

---Opens a code editor for this object.
---@param object Object
local function openCodeEditor(object)
  if not object.script then
    object.script = MakeResource("script") --[[@as Script]]
    object.script.code = ""
  end
  OpenResourceTab(object.script)
end

---@class SceneView: Zap.ElementClass
---@field editor SceneEditor
---@field engine Engine
---@field selectedObject Object?
---@field draggingObject {object: Object, offsetX: number, offsetY: number}
---@operator call:SceneView
local SceneView = zap.elementClass()

---@param editor SceneEditor
function SceneView:init(editor)
  self.editor = editor
  self.engine = editor.engine
  self.gridSize = 100
  self.panX, self.panY = 0, 0
  self.initialPanDone = false
  self.zoom = 1
  self.viewTransform = love.math.newTransform()
end

---Updates `viewTransform` according to the current values of `panX`, `panY` and `zoom`.
function SceneView:updateViewTransform()
  if self.spriteEditor then
    self.viewTransform
        :reset()
        :scale(self.spriteEditor.zoom, self.spriteEditor.zoom)
        :translate(
          self.spriteEditor.panX / self.spriteEditor.zoom - self.selectedObject.x,
          self.spriteEditor.panY / self.spriteEditor.zoom - self.selectedObject.y)
  else
    self.viewTransform
        :reset()
        :scale(self.zoom, self.zoom)
        :translate(-self.panX, -self.panY)
  end
end

function SceneView:doingNothing()
  return not self.creatingSprite and not self.creatingText
end

function SceneView:startCreatingSprite()
  if self.editingText then
    self:stopEditingText()
  end
  self.creatingSprite = true
  self.creationX = nil
  self.creationY = nil
end

function SceneView:startCreatingText()
  if self.editingText then
    self:stopEditingText()
  end
  self.creatingText = true
  self.creationX = nil
  self.creationY = nil
end

---Opens an embedded sprite editor.
---@param sprite Sprite
function SceneView:openSpriteEditor(sprite)
  if FocusResourceEditor(sprite.spriteData.id) then
    return
  end
  self.editingSprite = sprite
  self.editingSprite.visible = false
  self.spriteEditor = SpriteEditor(self)
  self.spriteEditor.editingSprite = sprite.spriteData
  self.spriteEditor.panX, self.spriteEditor.panY = self.viewTransform:transformPoint(sprite.x, sprite.y)
  self.spriteEditor.zoom = self.zoom
  if #sprite.spriteData.frames > 0 then
    self.spriteEditor:updateTransparencyQuad()
  end
end

---Closes the embedded sprite editor.
function SceneView:exitSpriteEditor()
  self.zoom = self.spriteEditor.zoom
  self.panX = -(self.spriteEditor.panX / self.spriteEditor.zoom - self.selectedObject.x)
  self.panY = -(self.spriteEditor.panY / self.spriteEditor.zoom - self.selectedObject.y)
  self.editingSprite.visible = true
  self.editingSprite = nil
  self.spriteEditor = nil
end

---@param text Text
function SceneView:startEditingText(text)
  self.editingText = text
  self.editingText.visible = false
  self.editingTextEditor = TextEditor()
  self.editingTextEditor.font = text.font
  self.editingTextEditor.multiline = true
  self.editingTextEditor:setText(text.string)
  self.editingTextEditor:flashCursor()
  self.editingTextEditor:nextRender(function(_)
    self.editingTextEditor:moveCursorToMouse()
  end)

  ---@type Zap.MouseTransform
  self.textEditMouseTransform = function(mouseX, mouseY)
    local x, y, _, _ = self:getView()
    mouseX = mouseX - x
    mouseY = mouseY - y
    mouseX, mouseY = self.viewTransform:inverseTransformPoint(mouseX, mouseY)
    return self.engine:getObjectTransform(text):inverseTransformPoint(mouseX, mouseY)
  end
end

function SceneView:stopEditingText()
  self:updateEditingText()
  self.editingText.visible = true
  self.editingText = nil
  self.editingTextEditor = nil
end

function SceneView:updateEditingText()
  self.editingText.string = self.editingTextEditor:getString()
  self.editingText.text:set(self.editingText.string)
end

---@param obj Object?
function SceneView:selectObject(obj)
  self.selectedObject = obj
  if obj then
    self.editor.propertiesPanel = DataPanel({
      {
        type = "vec2",
        text = "Position",
        targetObject = self.selectedObject,
        xKey = "x",
        yKey = "y"
      },
    })
    self.editor.propertiesPanel.text = "Properties"
    self.editor.propertiesPanel.icon = images["icons/properties_14.png"]
  else
    self.editor.propertiesPanel = nil
  end
end

---Returns the rectangle that the user drew when creating a Sprite or Text.
---@return number
---@return number
---@return number
---@return number
function SceneView:getCreationRect()
  local mx, my = self.viewTransform:inverseTransformPoint(self:getRelativeMouse())
  local x = math.min(mx, self.creationX)
  local y = math.min(my, self.creationY)
  local w = math.floor(math.abs(mx - self.creationX))
  local h = math.floor(math.abs(my - self.creationY))
  return x, y, w, h
end

function SceneView:mousePressed(button)
  if (self.creatingSprite or self.creatingText) and button == 1 then
    self.creationX, self.creationY = self.viewTransform:inverseTransformPoint(self:getRelativeMouse())
    return
  end
  if button == 1 or button == 2 then
    if self.editingText then
      self:stopEditingText()
    end
    self:selectObject(nil)
    local mx, my = self:getRelativeMouse()
    mx, my = self.viewTransform:inverseTransformPoint(mx, my)
    for i = #self.engine.objects.list, 1, -1 do
      ---@type Object
      local obj = self.engine.objects.list[i]
      local x, y, w, h = self.engine:getObjectBoundingBox(obj)
      if mx >= x and my >= y and mx < x + w and my < y + h then
        self:selectObject(obj)
        if button == 1 then
          self.draggingObject = {
            object = obj,
            offsetX = x - mx,
            offsetY = y - my,
          }
        end
        break
      end
    end
  end
  if button == 2 and self.selectedObject then
    local menu = PopupMenu()
    menu:setItems {
      {
        text = "Draw",
        action = function()
          self:openSpriteEditor(self.selectedObject --[[@as Sprite]])
        end,
        visible = self.selectedObject.type == "sprite"
      },
      {
        text = "Code",
        action = function()
          openCodeEditor(self.selectedObject)
        end
      },
      "separator",
      {
        text = "Remove",
        action = function()
          self.engine.objects:remove(self.selectedObject)
          self:selectObject(nil)
        end
      },
    }
    menu:popupAtCursor()
  elseif button == 3 then
    self.panning = true
    self.panStart = {
      worldX = self.panX,
      worldY = self.panY
    }
    self.panStart.screenX, self.panStart.screenY = self:getRelativeMouse()
  end
end

function SceneView:mouseReleased(button)
  if button == 1 then
    if self.creatingSprite then
      local x, y, w, h = self:getCreationRect()

      local newData = MakeResource("spriteData") --[[@as SpriteData]]
      newData.w = w
      newData.h = h
      newData.frames = {}

      ---@type Sprite
      local newSprite = {
        type = "sprite",
        x = x,
        y = y,
        spriteData = newData
      }
      self.engine:addObject(newSprite)
      self:openSpriteEditor(newSprite)
      self.spriteEditor:addFrame()
      self:selectObject(newSprite)

      self.creatingSprite = false
    elseif self.creatingText then
      local x, y, w, h = self:getCreationRect()

      local newText = self.engine:prepareObjectRuntime({
        type = "text",
        visible = true,
        x = x,
        y = y,
        string = "",
        fontSize = 32 -- TODO
      }) --[[@as Text]]
      self.engine:addObject(newText)
      self:selectObject(newText)
      self:startEditingText(newText)

      self.creatingText = false
    elseif self.draggingObject then
      self.draggingObject = nil
    end
  elseif button == 3 then
    self.panning = false
  end
end

function SceneView:mouseMoved(x, y)
  if self.draggingObject then
    x, y = self.viewTransform:inverseTransformPoint(x, y)
    self.draggingObject.object.x = x + self.draggingObject.offsetX
    self.draggingObject.object.y = y + self.draggingObject.offsetY
  elseif self.panning then
    local dx, dy = x - self.panStart.screenX, y - self.panStart.screenY
    self.panX = self.panStart.worldX - dx / self.zoom
    self.panY = self.panStart.worldY - dy / self.zoom
  end
end

function SceneView:mouseDoubleClicked(button)
  if button == 1 and self.selectedObject then
    if self.selectedObject.type == "sprite" then
      self:openSpriteEditor(self.selectedObject --[[@as Sprite]])
    elseif self.selectedObject.type == "text" then
      self:startEditingText(self.selectedObject --[[@as Text]])
    end
    self.draggingObject = nil
  end
end

function SceneView:wheelMoved(x, y)
  local newZoom = self.zoom
  if y > 0 then
    for i = 1, #zoomValues do
      if zoomValues[i] > self.zoom then
        newZoom = zoomValues[i]
        break
      end
    end
  elseif y < 0 then
    for i = #zoomValues, 1, -1 do
      if zoomValues[i] < self.zoom then
        newZoom = zoomValues[i]
        break
      end
    end
  end
  if newZoom ~= self.zoom then
    local prevWorldX, prevWorldY = self.viewTransform:inverseTransformPoint(self:getRelativeMouse())
    local diffX = (prevWorldX - self.panX) * self.zoom / newZoom
    local diffY = (prevWorldY - self.panY) * self.zoom / newZoom

    self.zoom = newZoom

    self.panX, self.panY = prevWorldX - diffX, prevWorldY - diffY

    if self.zoom <= 1 then
      self.panX, self.panY = math.floor(self.panX), math.floor(self.panY)
    end
  end
end

function SceneView:getCursor()
  if self.creatingSprite or self.creatingText then
    return love.mouse.getSystemCursor("crosshair")
  else
    return nil
  end
end

function SceneView:resized(w, h, prevW, prevH)
  self.panX = self.panX + (prevW - w) / 2 / self.zoom
  self.panY = self.panY + (prevH - h) / 2 / self.zoom
end

function SceneView:render(x, y, w, h)
  if not self.initialPanDone then
    self.initialPanDone = true
    self.panX = -math.floor(w / 2 - Project.currentProject.windowWidth / 2)
    self.panY = -math.floor(h / 2 - Project.currentProject.windowHeight / 2)
  end

  pushScissor(x, y, w, h)
  lg.push()
  lg.translate(x, y)
  self:updateViewTransform()
  lg.push()
  lg.applyTransform(self.viewTransform)

  do
    local x1, y1 = self.viewTransform:inverseTransformPoint(0, 0)
    local x2, y2 = self.viewTransform:inverseTransformPoint(w, h)
    lg.setLineStyle("rough")
    lg.setColor(1, 1, 1, 0.1) -- unstyled
    for lineX = math.ceil(x1 / self.gridSize) * self.gridSize, x2, self.gridSize do
      if lineX == 0 then
        lg.setLineWidth(3)
      else
        lg.setLineWidth(1)
      end
      lg.line(lineX, y1, lineX, y2)
    end
    for lineY = math.ceil(y1 / self.gridSize) * self.gridSize, y2, self.gridSize do
      if lineY == 0 then
        lg.setLineWidth(3)
      else
        lg.setLineWidth(1)
      end
      lg.line(x1, lineY, x2, lineY)
    end
  end

  lg.setColor(0.2, 0.6, 1, 0.2) -- unstyled
  lg.setLineWidth(2)
  lg.rectangle("line", 0, 0, Project.currentProject.windowWidth, Project.currentProject.windowHeight)

  self.engine:draw()

  for _, o in ipairs(self.engine.objects.list) do
    ---@cast o Object
    local ox, oy, ow, oh
    if o == self.editingText then
      ox, oy = self.selectedObject.x, self.selectedObject.y
      ow, oh = self.editingTextEditor:contentWidth(), self.editingTextEditor:contentHeight()
    else
      ox, oy, ow, oh = self.engine:getObjectBoundingBox(o)
    end
    lg.setColor(1, 1, 1, self.selectedObject == o and 0.5 or 0.2) -- unstyled
    lg.setLineWidth(1)
    lg.rectangle("line", ox, oy, ow, oh)
  end

  if self.editingText then
    lg.push()
    lg.applyTransform(self.engine:getObjectTransform(self.editingText))
    self:getScene():pushMouseTransform(self.textEditMouseTransform)
    self.editingTextEditor:render(
      0,
      0,
      self.editingTextEditor:contentWidth(),
      self.editingTextEditor:contentHeight())
    self:getScene():popMouseTransform()
    lg.pop()
  end

  lg.pop()

  if (self.creatingSprite or self.creatingText) and self.creationX then
    local x1, y1 = self.viewTransform:transformPoint(self.creationX, self.creationY)
    local x2, y2 = self:getRelativeMouse()
    lg.setColor(1, 1, 1, 0.2) -- unstyled
    lg.setLineWidth(2)
    lg.setLineStyle("rough")
    lg.rectangle("line", x1, y1, x2 - x1, y2 - y1)
  end

  lg.pop()
  popScissor()
end

---@class SceneEditor: ResourceEditor
---@field propertiesPanel DataPanel?
---@operator call:SceneEditor
local SceneEditor = zap.elementClass()

---@param scene Scene
function SceneEditor:init(scene)
  self.originalScene = scene
  self.engine = engine.createEngine(scene)

  self.sceneView = SceneView(self)

  self.toolbar = Toolbar()
  self.toolbar:setItems {
    {
      text = "New Sprite",
      image = images["icons/sprite_add_24.png"],
      action = function()
        self.sceneView:startCreatingSprite()
      end,
      enabled = function()
        return self.sceneView:doingNothing()
      end
    },
    {
      text = "New Text",
      image = images["icons/text_add_24.png"],
      action = function()
        self.sceneView:startCreatingText()
      end,
      enabled = function()
        return self.sceneView:doingNothing()
      end
    },
  }

  self.zoomSlider = ZoomSlider()
  self.zoomSlider.targetTable = self.sceneView
end

function SceneEditor:resourceId()
  return self.originalScene.id
end

function SceneEditor:editorTitle()
  return self.originalScene.name
end

function SceneEditor:writeToScene()
  if self.sceneView.editingText then
    self.sceneView:stopEditingText()
  end

  self.originalScene.objects = {}
  for _, o in ipairs(self.engine.objects.list) do
    table.insert(self.originalScene.objects, o)
  end
end

function SceneEditor:saveResource()
  self:writeToScene()
end

function SceneEditor:keyPressed(key)
  if key == "f9" and self.sceneView.selectedObject then
    openCodeEditor(self.sceneView.selectedObject)
  elseif self.sceneView.editingText then
    self.sceneView.editingTextEditor:keyPressed(key)
  end
end

function SceneEditor:textInput(text)
  if self.sceneView.editingText then
    self.sceneView.editingTextEditor:textInput(text)
  end
end

function SceneEditor:render(x, y, w, h)
  local toolbarH = self.toolbar:desiredHeight()

  self.sceneView:render(x, y + toolbarH, w, h - toolbarH)

  if self.sceneView.spriteEditor then
    lg.setColor(CurrentTheme.sceneEditorOverlay)
    lg.rectangle("fill", x, y, w, h)
    self.sceneView.spriteEditor:render(x, y, w, h)
  else
    self.toolbar:render(x, y, w, toolbarH)
  end

  if not self.sceneView.spriteEditor then
    local sliderW, sliderH = self.zoomSlider:desiredWidth() + 6, self.zoomSlider:desiredHeight() + 3
    self.zoomSlider:render(x + w - sliderW, y + h - sliderH, sliderW, sliderH)
  end

  if self.propertiesPanel and not self.sceneView.spriteEditor then
    local pw, ph = 240, 200
    local margin = 4
    self.propertiesPanel:render(x + margin, y + h - ph - margin, pw, ph)
  end
end

return SceneEditor
