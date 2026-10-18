--!strict
-- Машины: сервер ставит модель (корпус-коробка + внешний вид + место водителя). Ездой управляет клиент водителя
-- (VehicleController): физикой сидящего владеет его клиент, поэтому ввод с клавиатуры работает без задержек.
-- Модель — шаблон из ServerStorage.CarModels (Root — невидимая коробка-корпус, остальное — внешний вид без столкновений).
-- Позже: давить зомби (кроме боссов), турель на крыше (машина за 10 000 монет).

local ServerStorage = game:GetService("ServerStorage")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local VehicleService = {}

local container: Folder

-- Поставить машину (имя шаблона из ServerStorage.CarModels) в точку cf (основание на землю y = cf.Y)
function VehicleService.spawn(modelName: string, cf: CFrame): Model?
	local store = ServerStorage:FindFirstChild("CarModels")
	local template = store and store:FindFirstChild(modelName)
	if not template or not template:IsA("Model") or not template.PrimaryPart then
		warn("[VehicleService] нет шаблона машины " .. modelName)
		return nil
	end
	local model = template:Clone()
	model.Name = "Vehicle_" .. modelName
	local root = model.PrimaryPart :: BasePart
	model:ScaleTo(Config.Vehicle.length / root.Size.Z)
	model.Parent = container

	-- в шаблонах из Creator Store бывают свои сиденья (Seat/VehicleSeat) — убираем, водитель сядет на наше
	for _, d in model:GetDescendants() do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then
			d:Destroy()
		end
	end

	-- физика: корпус-коробка скользит почти без трения, остальные детали приварены и не мешают
	root.Anchored = false
	root.CanCollide = true
	root.CanQuery = true
	root.CustomPhysicalProperties = PhysicalProperties.new(0.5, 0, 0, 100, 1)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			local w = Instance.new("WeldConstraint")
			w.Part0 = root
			w.Part1 = d
			w.Parent = d
		end
	end

	-- место водителя в центре корпуса (невидимое); ввод читает VehicleController на клиенте водителя
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(2, 0.6, 2)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.Massless = true
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.Anchored = false
	seat.CFrame = root.CFrame * CFrame.new(0, -root.Size.Y / 2 + 1.6, root.Size.Z * 0.05)
	seat.Parent = model
	local sw = Instance.new("WeldConstraint")
	sw.Part0 = root
	sw.Part1 = seat
	sw.Parent = seat

	model:PivotTo(cf * CFrame.new(0, root.Size.Y / 2 + 0.3, 0))
	model:SetAttribute("Vehicle", true)
	return model
end

function VehicleService.init()
	container = Instance.new("Folder")
	container.Name = "Vehicles"
	container.Parent = workspace
end

return VehicleService
