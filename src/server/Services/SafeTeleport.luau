--!strict
-- Перенос игрока в далёкую часть карты. На карте включён стриминг: если перенести сразу, у клиента под ногами ещё нет пола и он падает в пустоту.
-- Поэтому игрока замораживаем, просим сервер загрузить место, переносим и какое-то время следим, что он не провалился.

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local SafeTeleport = {}

local tokens: { [Player]: number } = {} -- новый перенос отменяет предыдущий

local function holdAt(character: Model, root: BasePart, target: CFrame)
	root.Anchored = true
	character:PivotTo(target)
	task.wait(Config.SafeTeleport.HoldSeconds)
end

function SafeTeleport.move(player: Player, target: CFrame)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		return
	end
	local C = Config.SafeTeleport
	local token = (tokens[player] or 0) + 1
	tokens[player] = token
	local function alive(): boolean
		return tokens[player] == token and root.Parent ~= nil
	end
	root.Anchored = true
	task.spawn(function()
		local ok, err = pcall(function()
			player:RequestStreamAroundAsync(target.Position, C.StreamTimeout)
		end)
		if not ok then
			warn("[SafeTeleport] streaming request failed: " .. tostring(err))
		end
		if not alive() then
			return
		end
		holdAt(character, root, target)
		if not alive() then
			return
		end
		root.Anchored = false
		local stopAt = os.clock() + C.WatchSeconds
		while os.clock() < stopAt and alive() do
			if root.Position.Y < target.Position.Y - C.FallMargin then
				holdAt(character, root, target)
				if not alive() then
					return
				end
				root.Anchored = false
			end
			task.wait(0.2)
		end
	end)
end

Players.PlayerRemoving:Connect(function(player: Player)
	tokens[player] = nil
end)

return SafeTeleport
