--!strict
-- Живая 3D-иконка оружия для магазинов: ViewportFrame с копией модели из ReplicatedStorage.WeaponIcons, оружие лежит боком вдоль кадра.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local WeaponIcon = {}

-- Меши загружаем заранее, иначе при первом открытии магазина иконки пустые
task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild("WeaponIcons", 60)
	if folder then
		pcall(function()
			ContentProvider:PreloadAsync(folder:GetDescendants())
		end)
	end
end)

function WeaponIcon.make(parent: Instance, weaponId: string, position: UDim2, size: UDim2): ViewportFrame
	local view = Instance.new("ViewportFrame")
	view.Position = position
	view.Size = size
	view.BackgroundColor3 = Color3.fromRGB(28, 32, 23)
	view.BorderSizePixel = 0
	view.Ambient = Color3.fromRGB(205, 205, 190)
	view.LightColor = Color3.new(1, 1, 0.92)
	view.LightDirection = Vector3.new(-0.5, -1, -0.6)
	view.Parent = parent
	local folder = ReplicatedStorage:FindFirstChild("WeaponIcons")
	local src = folder and folder:FindFirstChild(weaponId)
	if not src or not src:IsA("Model") then
		return view
	end
	local model = src:Clone()
	model.Parent = view
	local cf, box = model:GetBoundingBox()
	-- смотрим вдоль самой тонкой оси, самая длинная лежит горизонтально
	local axes = { { dir = cf.RightVector, len = box.X }, { dir = cf.UpVector, len = box.Y }, { dir = cf.LookVector, len = box.Z } }
	table.sort(axes, function(a, b)
		return a.len < b.len
	end)
	local look, long = axes[1].dir, axes[3].dir
	local up = look:Cross(long).Unit
	if up:Dot(cf.UpVector) < 0 then
		up = -up
	end
	if Config.WeaponIconFlip[weaponId] then
		up = -up -- кадр поворачивается на 180°: рукоять вниз, дуло вправо, как у остального оружия
	end
	local cam = Instance.new("Camera")
	cam.FieldOfView = 24
	cam.Parent = view
	-- модель целиком в кадре при любых пропорциях окна
	local function frame()
		local px = view.AbsoluteSize
		local aspect = if px.Y > 0 and px.X > 0 then px.X / px.Y else 1.6
		local tanV = math.tan(math.rad(cam.FieldOfView) / 2)
		local dist = math.max((axes[3].len / 2) / (tanV * aspect), (axes[2].len / 2) / tanV) * 1.12
		cam.CFrame = CFrame.lookAt(cf.Position + look * dist, cf.Position, up)
	end
	frame()
	view:GetPropertyChangedSignal("AbsoluteSize"):Connect(frame)
	view.CurrentCamera = cam
	return view
end

return WeaponIcon
