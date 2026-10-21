--!strict
-- Выбор перка команды после босса: три карточки (клик или клавиши 1–3), таймер; выбранные перки команды — список слева.
-- Предложение и выбор проверяет сервер (PerkService); здесь только окно.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Perks = require(Shared:WaitForChild("Perks"))

local PerkController = {}

type Option = { id: string, name: string, desc: string, stacks: number, max: number }

function PerkController.start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "PerkHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Parent = player:WaitForChild("PlayerGui")

	-- список перков команды (слева, компактно)
	local list = Instance.new("TextLabel")
	list.AnchorPoint = Vector2.new(0, 0.5)
	list.Position = UDim2.new(0, 12, 0.5, 0)
	list.Size = UDim2.fromOffset(190, 20)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.BackgroundTransparency = 1
	list.TextXAlignment = Enum.TextXAlignment.Left
	list.TextYAlignment = Enum.TextYAlignment.Top
	list.Font = Enum.Font.GothamMedium
	list.TextSize = 14
	list.TextColor3 = Color3.fromRGB(240, 230, 200)
	list.TextStrokeTransparency = 0.5
	list.RichText = true
	list.Text = ""
	list.Parent = gui

	local function refreshList()
		local stacks = Perks.stacks()
		local lines: { string } = {}
		for _, def in Config.Perks do
			local n = stacks[def.id]
			if n and n > 0 then
				table.insert(lines, string.format("<b>%s</b> ×%d — %s", def.name, n, def.desc))
			end
		end
		list.Text = if #lines > 0 then "ПЕРКИ КОМАНДЫ\n" .. table.concat(lines, "\n") else ""
	end
	ReplicatedStorage:GetAttributeChangedSignal("Perks"):Connect(refreshList)
	refreshList()

	-- окно выбора
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.55
	overlay.Visible = false
	overlay.Parent = gui

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.14, 0)
	title.Size = UDim2.fromOffset(700, 44)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 30
	title.TextColor3 = Color3.fromRGB(255, 215, 80)
	title.Text = "Босс повержен — выберите перк для команды"
	title.Parent = overlay

	local timer = Instance.new("TextLabel")
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.new(0.5, 0, 0.14, 46)
	timer.Size = UDim2.fromOffset(500, 26)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.Gotham
	timer.TextSize = 18
	timer.TextColor3 = Color3.fromRGB(220, 220, 220)
	timer.Parent = overlay

	local row = Instance.new("Frame")
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.5)
	row.Size = UDim2.fromOffset(780, 250)
	row.BackgroundTransparency = 1
	row.Parent = overlay
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 20)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = row

	local currentId = 0
	local endsAt = 0
	local choose: (number) -> () = function() end

	local function close()
		overlay.Visible = false
		endsAt = 0
		ContextActionService:UnbindAction("NotdPerkPick")
	end

	local function show(offerId: number, options: { Option }, seconds: number)
		for _, c in row:GetChildren() do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		currentId = offerId
		endsAt = os.clock() + seconds
		local picked = false
		choose = function(index: number)
			if picked or not options[index] then
				return
			end
			picked = true
			Remotes.get("PerkChoose"):FireServer(currentId, index)
			title.Text = "Выбрано: " .. options[index].name
			timer.Text = "Ждём остальных игроков…"
			task.delay(1.2, function()
				if currentId == offerId then
					close()
				end
			end)
		end
		for i, opt in options do
			local def = Perks.byId(opt.id)
			local card = Instance.new("TextButton")
			card.Size = UDim2.fromOffset(230, 240)
			card.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
			card.AutoButtonColor = true
			card.Text = ""
			card.LayoutOrder = i
			card.Parent = row
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 10)
			corner.Parent = card
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 3
			stroke.Color = if def then def.color else Color3.new(1, 1, 1)
			stroke.Parent = card
			local key = Instance.new("TextLabel")
			key.Size = UDim2.fromOffset(40, 30)
			key.Position = UDim2.fromOffset(8, 6)
			key.BackgroundTransparency = 1
			key.Font = Enum.Font.GothamBold
			key.TextSize = 24
			key.TextColor3 = stroke.Color
			key.Text = tostring(i)
			key.Parent = card
			local name = Instance.new("TextLabel")
			name.Position = UDim2.fromOffset(10, 52)
			name.Size = UDim2.new(1, -20, 0, 52)
			name.BackgroundTransparency = 1
			name.Font = Enum.Font.GothamBold
			name.TextSize = 24
			name.TextWrapped = true
			name.TextColor3 = Color3.new(1, 1, 1)
			name.Text = opt.name
			name.Parent = card
			local desc = Instance.new("TextLabel")
			desc.Position = UDim2.fromOffset(10, 112)
			desc.Size = UDim2.new(1, -20, 0, 70)
			desc.BackgroundTransparency = 1
			desc.Font = Enum.Font.Gotham
			desc.TextSize = 19
			desc.TextWrapped = true
			desc.TextYAlignment = Enum.TextYAlignment.Top
			desc.TextColor3 = Color3.fromRGB(215, 215, 215)
			desc.Text = opt.desc
			desc.Parent = card
			local stacksLabel = Instance.new("TextLabel")
			stacksLabel.AnchorPoint = Vector2.new(0, 1)
			stacksLabel.Position = UDim2.new(0, 10, 1, -10)
			stacksLabel.Size = UDim2.new(1, -20, 0, 22)
			stacksLabel.BackgroundTransparency = 1
			stacksLabel.Font = Enum.Font.GothamMedium
			stacksLabel.TextSize = 15
			stacksLabel.TextColor3 = Color3.fromRGB(170, 170, 170)
			stacksLabel.Text = string.format("Уже взято: %d из %d", opt.stacks, opt.max)
			stacksLabel.Parent = card
			card.Activated:Connect(function()
				choose(i)
			end)
		end
		title.Text = "Босс повержен — выберите перк для команды"
		overlay.Visible = true
		ContextActionService:BindActionAtPriority("NotdPerkPick", function(_, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			local index = if input.KeyCode == Enum.KeyCode.One then 1 elseif input.KeyCode == Enum.KeyCode.Two then 2 elseif input.KeyCode == Enum.KeyCode.Three then 3 else 0
			if index > 0 then
				choose(index)
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three)
	end

	Remotes.get("PerkOffer").OnClientEvent:Connect(function(offerId: number, options: { Option }, seconds: number)
		local ok, err = pcall(show, offerId, options, seconds)
		if not ok then
			warn("[PerkController] " .. tostring(err))
		end
	end)
	RunService.Heartbeat:Connect(function()
		if overlay.Visible and endsAt > 0 then
			local left = math.max(0, endsAt - os.clock())
			timer.Text = string.format("Выбор: 1 / 2 / 3 или клик · осталось %d с (иначе случайно)", math.ceil(left))
		end
	end)
end

return PerkController
