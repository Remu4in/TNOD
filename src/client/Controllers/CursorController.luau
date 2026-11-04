--!strict
-- Курсор мыши в центре экрана убран: в виде от первого лица мышь привязана к камере и значок только мешает (прицел — HUD при прицеливании).
-- В окнах (видимая Modal-кнопка отпускает мышь) и там, где мышь свободна, значок возвращается.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CursorController = {}

local function reallyVisible(button: GuiObject): boolean
	local node: Instance? = button
	while node do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		elseif node:IsA("ScreenGui") then
			return node.Enabled
		end
		node = node.Parent
	end
	return false
end

function CursorController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local buttons: { [GuiButton]: boolean } = {}
	local function watch(d: Instance)
		if d:IsA("GuiButton") then
			buttons[d] = true
		end
	end
	for _, d in playerGui:GetDescendants() do
		watch(d)
	end
	playerGui.DescendantAdded:Connect(watch)
	playerGui.DescendantRemoving:Connect(function(d: Instance)
		if d:IsA("GuiButton") then
			buttons[d] = nil
		end
	end)
	local acc = 0
	local windowOpen = false
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= 0.15 then
			acc = 0
			windowOpen = false
			for b in buttons do
				if b.Modal and reallyVisible(b) then
					windowOpen = true
					break
				end
			end
		end
		local want = windowOpen or UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
		if UserInputService.MouseIconEnabled ~= want then
			UserInputService.MouseIconEnabled = want
		end
	end)
end

return CursorController
