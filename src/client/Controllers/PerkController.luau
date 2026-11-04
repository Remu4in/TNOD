--!strict
-- Выбор перка команды после босса: три карточки (клик, касание, стрелки геймпада или клавиши 1–3), таймер; выбранные перки команды — список слева.
-- Предложение и выбор проверяет сервер (PerkService); здесь только окно. Пока окно открыто, курсор свободен (Modal-кнопка + MouseBehavior),
-- камера не вращается, у карточек есть выбор геймпадом (GuiService.SelectedObject). Вид: военно-зомби — тёмный камуфляж, трафаретные коды,
-- цветная полоса вида, шкала стаков, полоса таймера; появление и выбор анимируются через TweenService.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Perks = require(Shared:WaitForChild("Perks"))

local PerkController = {}

type Option = { id: string, name: string, desc: string, stacks: number, max: number }

-- Трафаретный код вида перка на «иконке»
local KIND_CODE: { [string]: string } = {
	health = "HP", stamina = "STA", mag = "MAG", speed = "SPD", power = "DMG", reload = "RLD", ammo = "AMO", revive = "MED", coins = "$$$",
}

local BG = Color3.fromRGB(20, 24, 20)
local PANEL = Color3.fromRGB(30, 36, 30)
local TEXT = Color3.fromRGB(232, 228, 210)
local DIM = Color3.fromRGB(150, 156, 140)

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
	list.TextColor3 = TEXT
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
		list.Text = if #lines > 0 then "TEAM PERKS\n" .. table.concat(lines, "\n") else ""
	end
	ReplicatedStorage:GetAttributeChangedSignal("Perks"):Connect(refreshList)
	refreshList()

	-- окно выбора
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.4
	overlay.Visible = false
	overlay.Parent = gui

	-- Modal-кнопка отпускает курсор в режиме от первого лица (так же, как окна лобби)
	local modalBtn = Instance.new("TextButton")
	modalBtn.Name = "ModalCursor"
	modalBtn.Size = UDim2.fromOffset(0, 0)
	modalBtn.BackgroundTransparency = 1
	modalBtn.Text = ""
	modalBtn.Modal = false
	modalBtn.Parent = overlay

	local scale = Instance.new("UIScale")
	scale.Parent = overlay

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.1, 0)
	title.Size = UDim2.fromOffset(760, 48)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Oswald
	title.TextSize = 38
	title.TextColor3 = Color3.fromRGB(214, 190, 96)
	title.Text = "BOSS DOWN — CHOOSE A TEAM PERK"
	title.Parent = overlay

	local timer = Instance.new("TextLabel")
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.new(0.5, 0, 0.1, 50)
	timer.Size = UDim2.fromOffset(600, 24)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.GothamMedium
	timer.TextSize = 17
	timer.TextColor3 = DIM
	timer.Parent = overlay

	local barBack = Instance.new("Frame")
	barBack.AnchorPoint = Vector2.new(0.5, 0)
	barBack.Position = UDim2.new(0.5, 0, 0.1, 80)
	barBack.Size = UDim2.fromOffset(420, 6)
	barBack.BackgroundColor3 = Color3.fromRGB(46, 50, 44)
	barBack.BorderSizePixel = 0
	barBack.Parent = overlay
	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromScale(1, 1)
	bar.BackgroundColor3 = Color3.fromRGB(180, 60, 50)
	bar.BorderSizePixel = 0
	bar.Parent = barBack

	local row = Instance.new("Frame")
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.54)
	row.Size = UDim2.fromOffset(820, 330)
	row.BackgroundTransparency = 1
	row.Parent = overlay
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 18)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row

	local currentId = 0
	local endsAt = 0
	local total = 30
	local choose: (number) -> () = function() end
	local cards: { CanvasGroup } = {}

	local function setCursorFree(free: boolean)
		modalBtn.Modal = free
		UserInputService.MouseIconEnabled = free or UserInputService.MouseIconEnabled
		if free then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		else
			GuiService.SelectedObject = nil
		end
	end

	local function close()
		overlay.Visible = false
		endsAt = 0
		setCursorFree(false)
		ContextActionService:UnbindAction("NotdPerkPick")
	end

	-- под размер экрана: окно рассчитано на 900×560; на телефоне уменьшаем
	local function fit()
		local view = gui.AbsoluteSize
		scale.Scale = math.clamp(math.min(view.X / 900, view.Y / 560), 0.55, 1.15)
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()

	local function show(offerId: number, options: { Option }, seconds: number)
		for _, c in row:GetChildren() do
			if c:IsA("CanvasGroup") then
				c:Destroy()
			end
		end
		table.clear(cards)
		currentId = offerId
		total = math.max(1, seconds)
		endsAt = os.clock() + seconds
		local picked = false
		choose = function(index: number)
			if picked or not options[index] then
				return
			end
			picked = true
			endsAt = 0 -- таймер больше не перетирает «Waiting…», окно закроет task.delay ниже
			Remotes.get("PerkChoose"):FireServer(currentId, index)
			title.Text = "CHOSEN: " .. string.upper(options[index].name)
			timer.Text = "Waiting for the other players…"
			for i, card in cards do
				local chosen = i == index
				TweenService:Create(card, TweenInfo.new(0.25), { GroupTransparency = if chosen then 0 else 0.65 }):Play()
				local cardScale = card:FindFirstChildOfClass("UIScale")
				if cardScale then
					TweenService:Create(cardScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = if chosen then 1.1 else 0.92 }):Play()
				end
			end
			task.delay(1.2, function()
				if currentId == offerId then
					close()
				end
			end)
		end
		for i, opt in options do
			local def = Perks.byId(opt.id)
			local accent = if def then def.color else Color3.new(1, 1, 1)
			local card = Instance.new("CanvasGroup")
			card.Name = "Card" .. i
			card.Size = UDim2.fromOffset(240, 310)
			card.BackgroundColor3 = BG
			card.GroupTransparency = 1
			card.LayoutOrder = i
			card.Parent = row
			table.insert(cards, card)
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 6)
			corner.Parent = card
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 2
			stroke.Color = accent
			stroke.Transparency = 0.2
			stroke.Parent = card
			local cs = Instance.new("UIScale")
			cs.Scale = 0.82
			cs.Parent = card

			-- цветная полоса вида сверху
			local stripe = Instance.new("Frame")
			stripe.Size = UDim2.new(1, 0, 0, 8)
			stripe.BackgroundColor3 = accent
			stripe.BorderSizePixel = 0
			stripe.Parent = card
			-- иконка: тёмный диск с трафаретным кодом
			local icon = Instance.new("Frame")
			icon.AnchorPoint = Vector2.new(0.5, 0)
			icon.Position = UDim2.new(0.5, 0, 0, 24)
			icon.Size = UDim2.fromOffset(84, 84)
			icon.BackgroundColor3 = PANEL
			icon.Parent = card
			local ic = Instance.new("UICorner")
			ic.CornerRadius = UDim.new(1, 0)
			ic.Parent = icon
			local is = Instance.new("UIStroke")
			is.Thickness = 3
			is.Color = accent
			is.Parent = icon
			local code = Instance.new("TextLabel")
			code.Size = UDim2.fromScale(1, 1)
			code.BackgroundTransparency = 1
			code.Font = Enum.Font.Oswald
			code.TextSize = if #(KIND_CODE[def and def.kind or ""] or "?") > 3 then 24 else 30
			code.TextColor3 = accent
			code.Text = KIND_CODE[def and def.kind or ""] or "?"
			code.Parent = icon
			-- номер клавиши
			local key = Instance.new("TextLabel")
			key.Position = UDim2.fromOffset(10, 14)
			key.Size = UDim2.fromOffset(26, 22)
			key.BackgroundColor3 = PANEL
			key.Font = Enum.Font.GothamBold
			key.TextSize = 15
			key.TextColor3 = DIM
			key.Text = tostring(i)
			key.Parent = card
			local kc = Instance.new("UICorner")
			kc.CornerRadius = UDim.new(0, 4)
			kc.Parent = key

			local name = Instance.new("TextLabel")
			name.Position = UDim2.fromOffset(12, 122)
			name.Size = UDim2.new(1, -24, 0, 34)
			name.BackgroundTransparency = 1
			name.Font = Enum.Font.Oswald
			name.TextSize = 27
			name.TextColor3 = TEXT
			name.Text = string.upper(opt.name)
			name.Parent = card
			local desc = Instance.new("TextLabel")
			desc.Position = UDim2.fromOffset(14, 160)
			desc.Size = UDim2.new(1, -28, 0, 60)
			desc.BackgroundTransparency = 1
			desc.Font = Enum.Font.Gotham
			desc.TextSize = 17
			desc.TextWrapped = true
			desc.TextYAlignment = Enum.TextYAlignment.Top
			desc.TextColor3 = Color3.fromRGB(205, 205, 190)
			desc.Text = opt.desc
			desc.Parent = card

			-- шкала стаков: взято (цвет), следующий (контур), свободно (тёмные)
			local pips = Instance.new("Frame")
			pips.AnchorPoint = Vector2.new(0.5, 1)
			pips.Position = UDim2.new(0.5, 0, 1, -38)
			pips.Size = UDim2.new(1, -28, 0, 14)
			pips.BackgroundTransparency = 1
			pips.Parent = card
			local pl = Instance.new("UIListLayout")
			pl.FillDirection = Enum.FillDirection.Horizontal
			pl.Padding = UDim.new(0, 4)
			pl.HorizontalAlignment = Enum.HorizontalAlignment.Center
			pl.Parent = pips
			for s = 1, opt.max do
				local pip = Instance.new("Frame")
				pip.Size = UDim2.fromOffset(math.min(30, math.floor(190 / opt.max)), 12)
				pip.BorderSizePixel = 0
				pip.BackgroundColor3 = if s <= opt.stacks then accent else Color3.fromRGB(52, 58, 50)
				pip.LayoutOrder = s
				pip.Parent = pips
				if s == opt.stacks + 1 then
					local ps = Instance.new("UIStroke")
					ps.Color = accent
					ps.Thickness = 1.5
					ps.Parent = pip
				end
			end
			local stacksLabel = Instance.new("TextLabel")
			stacksLabel.AnchorPoint = Vector2.new(0, 1)
			stacksLabel.Position = UDim2.new(0, 14, 1, -10)
			stacksLabel.Size = UDim2.new(1, -28, 0, 20)
			stacksLabel.BackgroundTransparency = 1
			stacksLabel.Font = Enum.Font.GothamMedium
			stacksLabel.TextSize = 14
			stacksLabel.TextColor3 = DIM
			stacksLabel.Text = if opt.stacks >= opt.max then "MAXED" else string.format("STACKS %d / %d", opt.stacks, opt.max)
			stacksLabel.Parent = card

			-- кнопка на всю карточку: мышь, касание, геймпад
			local btn = Instance.new("TextButton")
			btn.Name = "Pick"
			btn.Size = UDim2.fromScale(1, 1)
			btn.BackgroundTransparency = 1
			btn.Text = ""
			btn.Selectable = true
			btn.ZIndex = 10
			btn.Parent = card
			btn.Activated:Connect(function()
				choose(i)
			end)
			btn.MouseEnter:Connect(function()
				if not picked then
					TweenService:Create(cs, TweenInfo.new(0.12), { Scale = 1.04 }):Play()
				end
			end)
			btn.MouseLeave:Connect(function()
				if not picked then
					TweenService:Create(cs, TweenInfo.new(0.12), { Scale = 1 }):Play()
				end
			end)
			btn.SelectionGained:Connect(function()
				TweenService:Create(cs, TweenInfo.new(0.12), { Scale = 1.06 }):Play()
			end)
			btn.SelectionLost:Connect(function()
				TweenService:Create(cs, TweenInfo.new(0.12), { Scale = 1 }):Play()
			end)

			-- появление: по очереди, с отскоком
			task.delay(0.08 * (i - 1), function()
				if card.Parent then
					TweenService:Create(card, TweenInfo.new(0.3), { GroupTransparency = 0 }):Play()
					TweenService:Create(cs, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
				end
			end)
		end
		title.Text = "BOSS DOWN — CHOOSE A TEAM PERK"
		overlay.BackgroundTransparency = 1
		TweenService:Create(overlay, TweenInfo.new(0.25), { BackgroundTransparency = 0.4 }):Play()
		overlay.Visible = true
		setCursorFree(true)
		local first = cards[1] and cards[1]:FindFirstChild("Pick")
		if first and first:IsA("GuiObject") and UserInputService.GamepadEnabled then
			GuiService.SelectedObject = first
		end
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
		if not overlay.Visible then
			return
		end
		-- курсор держим свободным, пока окно открыто (камера первого лица пытается вернуть Lock)
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if endsAt > 0 then
			-- сервер сам выбирает перк по таймауту (30 + 1 с) и клиенту не сообщает — закрываем окно сами
			if os.clock() >= endsAt + 1.5 then
				close()
				return
			end
			local left = math.max(0, endsAt - os.clock())
			timer.Text = string.format("Click, tap, D-pad or press 1 / 2 / 3 · %d s left (otherwise random)", math.ceil(left))
			bar.Size = UDim2.fromScale(math.clamp(left / total, 0, 1), 1)
		end
	end)
end

return PerkController
