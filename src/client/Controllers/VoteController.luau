--!strict
-- Голосование за досрочное завершение дня: кнопка (и клавиша V) внизу слева, пока идёт день.
-- Сервер считает голоса (RoundService); день завершается, когда проголосовали все игроки.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local VoteController = {}

function VoteController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "DayVote"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0, 1)
	button.Position = UDim2.new(0, 16, 1, -16)
	button.Size = UDim2.fromOffset(250, 48)
	button.BackgroundColor3 = Color3.fromRGB(34, 37, 44)
	button.BackgroundTransparency = 0.1
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local function refresh()
		local day = ReplicatedStorage:GetAttribute("Phase") == "Day"
		gui.Enabled = day
		local votes = (ReplicatedStorage:GetAttribute("DayVotes") :: number?) or 0
		local need = (ReplicatedStorage:GetAttribute("DayVoteNeed") :: number?) or 0
		local mine = player:GetAttribute("VotedDay") == true
		button.Text = string.format("%s (V)  %d/%d", if mine then "Готов — отменить" else "Завершить день", votes, need)
		button.BackgroundColor3 = if mine then Color3.fromRGB(60, 130, 70) else Color3.fromRGB(34, 37, 44)
	end
	for _, name in { "Phase", "DayVotes", "DayVoteNeed" } do
		ReplicatedStorage:GetAttributeChangedSignal(name):Connect(refresh)
	end
	player:GetAttributeChangedSignal("VotedDay"):Connect(refresh)
	button.Activated:Connect(function()
		Remotes.get("VoteDay"):FireServer()
	end)
	ContextActionService:BindAction("VoteDay", function(_, state)
		if state == Enum.UserInputState.Begin and gui.Enabled then
			Remotes.get("VoteDay"):FireServer()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.V)
	refresh()
end

return VoteController
