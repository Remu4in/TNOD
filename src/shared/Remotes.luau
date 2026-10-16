--!strict
-- Сетевые события. Сервер создаёт, клиент ждёт.
-- Состояние раунда передаётся атрибутами (ReplicatedStorage и Player), события — только для действий.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMES = {
	"Fire", -- клиент → сервер: (origin: Vector3, direction: Vector3)
	"Reload", -- клиент → сервер: ()
	"HitFeedback", -- сервер → стрелку: (position: Vector3, damage: number, killed: boolean, headshot: boolean)
	"ShotFx", -- сервер → всем: (shooter: Player, origin: Vector3, hits: {Vector3}, weaponId: string)
	"ReloadFx", -- сервер → всем: (player: Player, weaponId: string) — звук перезарядки
	"Notify", -- сервер → клиенту/всем: (text: string, seconds: number)
}

local Remotes = {}

local function folder(): Folder
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("Remotes")
		if not f then
			local nf = Instance.new("Folder")
			nf.Name = "Remotes"
			for _, name in NAMES do
				local ev = Instance.new("RemoteEvent")
				ev.Name = name
				ev.Parent = nf
			end
			nf.Parent = ReplicatedStorage
			f = nf
		end
		return f :: Folder
	end
	return ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Remotes.get(name: string): RemoteEvent
	return folder():WaitForChild(name) :: RemoteEvent
end

return Remotes
