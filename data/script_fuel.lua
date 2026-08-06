-- Fuel system: tank damage (leakage) and fuel exhaustion simulation at low fuel levels.

require "script_car_parameters"

-- Internal defaults for the manual fuel tank pressurization model.
fuelTankMaximumPressurePsi = fuelTankMaximumPressurePsi or fuelTankOptimalPressurePsi * 1.8
fuelTankInitialPressurePsi = fuelTankInitialPressurePsi or fuelTankOptimalPressurePsi
fuelTankPressurePumpActiveDisplaySeconds = fuelTankPressurePumpActiveDisplaySeconds or 0.35
fuelTankPressureCutCheckIntervalSeconds = fuelTankPressureCutCheckIntervalSeconds or 1.0
fuelTankPressureCutLengthMinSeconds = fuelTankPressureCutLengthMinSeconds or 0.15
fuelTankPressureCutLengthMaxSeconds = fuelTankPressureCutLengthMaxSeconds or 0.8
fuelTankPressureCutSeverityMultiplier = fuelTankPressureCutSeverityMultiplier or 0.8
fuelTankPressureAutomaticAssistantEnabled = fuelTankPressureAutomaticAssistantEnabled or false
fuelTankPressureAutomaticPumpStartPsi = fuelTankPressureAutomaticPumpStartPsi or fuelTankLowPressureWarningPsi + 0.4
fuelTankPressureAutomaticPumpIntervalSeconds = fuelTankPressureAutomaticPumpIntervalSeconds or 0.6

-- Shared state (globals)
fuelLeakageDamage = false
fuelExhCutLength = 0
fuelExhCutTimer = 0
fuelTankPressurePsi = fuelTankInitialPressurePsi
fuelTankPressurizationPumpActive = false
fuelTankPressureLow = false
fuelTankPressureFuelCutActive = false

-- Module-local state
local normalFuelConsumptionRate = acCarPhysics.fuelConsumption
local fuelExhState = 0
local fuelExhStartCount = 0
local fuelExhStartCounter = 0
local fuelDependentGForceThreshold = 0
local fuelExhInterval = 0
local fuelExhIntervalCounter = 0
local previousFuelLitres = thisCar.fuel
local previousExtraGState = false
local fuelLeakageDamageChanceValue = fuelLeakageDamageChance or 0.25
local fuelTankPressurePumpActiveTimer = 0
local fuelTankPressureCutTimer = 0
local fuelTankPressureWarningTimer = 0
local fuelTankPressureCutInProgress = false
local fuelTankPressureDebugTimer = 0
local fuelTankPressureAutomaticPumpTimer = 0
local fuelLeakageDamageRollDone = false
local fuelLeakageLastRolledDamage = 0

function fuelTankDamage()
    local cumulativeDamage = 0

    for i = 0, 3 do
        if fuelLeakageDamageSides[i + 1] then
            cumulativeDamage = cumulativeDamage + thisCar.damage[i]
        end
    end

    printDebug("Cumulative damage for fuel leakage", cumulativeDamage)

    if cumulativeDamage > fuelLeakageDamageThreshold then
        if not fuelLeakageDamage and (not fuelLeakageDamageRollDone or cumulativeDamage > fuelLeakageLastRolledDamage) then
            fuelLeakageDamageRollDone = true
            fuelLeakageLastRolledDamage = cumulativeDamage
            fuelLeakageDamage = math.random() < fuelLeakageDamageChanceValue
        end

        if not fuelLeakageDamage then
            ac.setFuelConsumption(normalFuelConsumptionRate)
            printDebug("Fuel consumption rate", normalFuelConsumptionRate)
            return
        end

        local fuelConsumptionRate = normalFuelConsumptionRate + cumulativeDamage / 100

        if fuelConsumptionRate > 1 then
            fuelConsumptionRate = 1
        end

        ac.setFuelConsumption(fuelConsumptionRate)
        printDebug("Fuel consumption rate", fuelConsumptionRate)
        fuelLeakageDamage = true
    else
        ac.setFuelConsumption(normalFuelConsumptionRate)
        printDebug("Fuel consumption rate", normalFuelConsumptionRate)
        fuelLeakageDamage = false
        fuelLeakageDamageRollDone = false
        fuelLeakageLastRolledDamage = 0
    end
end

local function clampNumber(value, minimumValue, maximumValue)
    return math.max(minimumValue, math.min(maximumValue, value))
end

local function addFuelTankPressurePumpStroke()
    fuelTankPressurePsi = clampNumber(fuelTankPressurePsi + fuelTankPressurePumpGainPsi, 0, fuelTankMaximumPressurePsi)
    fuelTankPressurizationPumpActive = true
    fuelTankPressurePumpActiveTimer = fuelTankPressurePumpActiveDisplaySeconds
end

local function updateFuelTankPressurePumpInput(dt)
    if fuelTankPressurePumpActiveTimer > 0 then
        fuelTankPressurePumpActiveTimer = math.max(0, fuelTankPressurePumpActiveTimer - dt)
        fuelTankPressurizationPumpActive = true
    else
        fuelTankPressurizationPumpActive = false
    end

    if fuelTankPressureAutomaticAssistantEnabled then
        previousExtraGState = thisCar.extraG
        return
    end

    -- Extra G represents one air pump stroke into the fuel tank. If Extra C is
    -- also active, let the oil pump own that input frame to avoid mixed binds.
    if thisCar.extraG and not thisCar.extraC and not previousExtraGState then
        addFuelTankPressurePumpStroke()
        overheadMessageQueue("Fuel pressure", "Air pumped into fuel tank", 2, true)
    end

    previousExtraGState = thisCar.extraG
end

local function updateFuelTankPressureFromFuelUse(dt)
    local currentFuelLitres = thisCar.fuel or previousFuelLitres
    local fuelUsedLitres = math.max(0, previousFuelLitres - currentFuelLitres)
    previousFuelLitres = currentFuelLitres

    fuelTankPressurePsi = fuelTankPressurePsi - fuelUsedLitres * fuelTankPressureLossPerFuelLitre
    fuelTankPressurePsi = fuelTankPressurePsi - fuelTankPressureNaturalLossPerSecond * dt

    -- A punctured tank or fuel line bleeds pressure too, but mildly enough that
    -- the driver can usually keep the car alive by pumping more often.
    if fuelLeakageDamage then
        fuelTankPressurePsi = fuelTankPressurePsi - fuelTankPressureLeakDamageLossPerSecond * dt
    end

    fuelTankPressurePsi = clampNumber(fuelTankPressurePsi, 0, fuelTankMaximumPressurePsi)
end

local function updateAutomaticFuelTankPressureAssistant(dt)
    if not fuelTankPressureAutomaticAssistantEnabled then
        fuelTankPressureAutomaticPumpTimer = 0
        return
    end

    fuelTankPressureAutomaticPumpTimer = fuelTankPressureAutomaticPumpTimer + dt

    if fuelTankPressurePsi < fuelTankPressureAutomaticPumpStartPsi
            and fuelTankPressureAutomaticPumpTimer >= fuelTankPressureAutomaticPumpIntervalSeconds then
        addFuelTankPressurePumpStroke()
        fuelTankPressureAutomaticPumpTimer = 0
    end
end

local function updateFuelTankPressureCuts(dt)
    fuelTankPressureLow = fuelTankPressurePsi < fuelTankLowPressureWarningPsi

    if fuelTankPressureCutInProgress then
        fuelTankPressureFuelCutActive = fuelExhCutLength > 0

        if not fuelTankPressureFuelCutActive then
            fuelTankPressureCutInProgress = false
        end
    else
        fuelTankPressureFuelCutActive = false
    end

    if fuelTankPressurePsi >= fuelTankMinimumFuelFeedPressurePsi then
        fuelTankPressureCutTimer = 0
        return
    end

    fuelTankPressureCutTimer = fuelTankPressureCutTimer + dt

    if fuelTankPressureCutTimer >= fuelTankPressureCutCheckIntervalSeconds and fuelExhCutLength <= 0 then
        local pressureShortfall = fuelTankMinimumFuelFeedPressurePsi - fuelTankPressurePsi
        local pressureSeverity = clampNumber(pressureShortfall / math.max(fuelTankMinimumFuelFeedPressurePsi, 0.001), 0, 1)
        local randomCutLength = fuelTankPressureCutLengthMinSeconds + math.random() * (fuelTankPressureCutLengthMaxSeconds - fuelTankPressureCutLengthMinSeconds)

        fuelExhCutLength = randomCutLength * (0.35 + pressureSeverity * fuelTankPressureCutSeverityMultiplier)
        fuelExhCutTimer = 0
        fuelTankPressureFuelCutActive = true
        fuelTankPressureCutInProgress = true
        fuelTankPressureCutTimer = 0
    end
end

local function updateFuelTankPressureMessages(dt)
    fuelTankPressureWarningTimer = fuelTankPressureWarningTimer + dt

    if fuelTankPressureLow and fuelTankPressureWarningTimer > 8 then
        local warningMessage = fuelTankPressureAutomaticAssistantEnabled
            and "Riding mechanic is pumping air into the tank"
            or "Pump air into the tank with Extra G"
        overheadMessageQueue("Fuel tank pressure", warningMessage, 4, true)
        fuelTankPressureWarningTimer = 0
    end
end

local function updateFuelTankPressureDebug(dt)
    fuelTankPressureDebugTimer = fuelTankPressureDebugTimer + dt

    if fuelTankPressureDebugTimer >= 0.5 then
        printDebug("Fuel tank pressure", string.format("%.2f psi", fuelTankPressurePsi))
        printDebug("Fuel pressure pump", tostring(fuelTankPressurizationPumpActive))
        printDebug("Fuel pressure low", tostring(fuelTankPressureLow))
        printDebug("Fuel pressure cut", tostring(fuelTankPressureFuelCutActive))
        fuelTankPressureDebugTimer = 0
    end
end

function resetFuelTankPressurization()
    fuelTankPressurePsi = fuelTankInitialPressurePsi
    fuelTankPressurizationPumpActive = false
    fuelTankPressureLow = false
    fuelTankPressureFuelCutActive = false
    previousFuelLitres = thisCar.fuel
    previousExtraGState = false
    fuelTankPressurePumpActiveTimer = 0
    fuelTankPressureCutTimer = 0
    fuelTankPressureWarningTimer = 0
    fuelTankPressureCutInProgress = false
    fuelTankPressureDebugTimer = 0
    fuelTankPressureAutomaticPumpTimer = 0
    fuelLeakageDamageRollDone = false
    fuelLeakageLastRolledDamage = 0
end

function setManualFuelPressureDriverEnabled(enabled)
    fuelTankPressureAutomaticAssistantEnabled = manualFuelPressurizationEnabled and not enabled
end

function isManualFuelPressureDriverEnabled()
    return manualFuelPressurizationEnabled and not fuelTankPressureAutomaticAssistantEnabled
end

function updateFuelTankPressurization(dt)
    if not manualFuelPressurizationEnabled then
        if fuelTankPressureCutInProgress then
            fuelExhCutLength = 0
            fuelExhCutTimer = 0
        end

        fuelTankPressurePsi = fuelTankOptimalPressurePsi
        fuelTankPressurizationPumpActive = false
        fuelTankPressureLow = false
        fuelTankPressureFuelCutActive = false
        previousFuelLitres = thisCar.fuel
        fuelTankPressureCutInProgress = false
    else
        updateFuelTankPressurePumpInput(dt)
        updateFuelTankPressureFromFuelUse(dt)
        updateAutomaticFuelTankPressureAssistant(dt)
        updateFuelTankPressureCuts(dt)
        updateFuelTankPressureMessages(dt)
    end

    updateFuelTankPressureDebug(dt)

    acCarPhysics.controllerInputs[63] = manualFuelPressurizationEnabled
    acCarPhysics.controllerInputs[64] = fuelTankPressurePsi
    acCarPhysics.controllerInputs[65] = fuelTankPressurizationPumpActive
    acCarPhysics.controllerInputs[66] = fuelTankPressureLow
    acCarPhysics.controllerInputs[67] = fuelTankPressureFuelCutActive
    acCarPhysics.controllerInputs[68] = fuelTankPressurePsi / math.max(fuelTankOptimalPressurePsi, 0.001)
end

function fuelExhaustion()
    printDebug("Fuel, fuelExhState", fuelExhState)
    -- Adjust the g-force threshold based on the current fuel level. The less fuel we have,
    -- the easier it is to trigger a stall.
    fuelDependentGForceThreshold = fuelExhaustionGForceThreshold * (thisCar.fuel / fuelExhaustionAmount)
    printDebug("Fuel, G-force", fuelDependentGForceThreshold)

    -- Idle state.
    if fuelExhState == 0 then
        if math.abs(acCarPhysics.gForces.x) > fuelDependentGForceThreshold and thisCar.fuel < fuelExhaustionAmount then
            fuelExhStartCount = thisCar.fuel
            fuelExhStartCounter = 0
            fuelExhCutLength = 0
            fuelExhInterval = 0
            fuelExhIntervalCounter = 0
            fuelExhState = 10
        end
    -- Stall detection state. Wait for enough g-force events to trigger a stall. The less we have fuel,
    -- the easier it is to trigger a stall.
    elseif fuelExhState == 10 then
        if math.abs(acCarPhysics.gForces.x) > fuelDependentGForceThreshold then
            fuelExhStartCounter = fuelExhStartCounter + 1
        else
            fuelExhStartCounter = 0
            fuelExhState = 0
        end

        if fuelExhStartCounter >= fuelExhStartCount then
            fuelExhCutLength = math.random() * (fuelExhaustionAmount - thisCar.fuel) / fuelExhaustionAmount / 2
            -- Take the speed of the car into account: under 100 km/h the cut length is minimal, but at higher speeds
            -- the cut length increases quadratically.
            fuelExhCutLength = fuelExhCutLength + (thisCar.speedKmh / 100) ^ 2
            printDebug("Fuel, cut length", fuelExhCutLength)
            fuelExhInterval = math.random() * 2
            fuelExhState = 20
        end
    -- Fuel cut active state.
    elseif fuelExhState == 20 then
        if fuelExhCutLength == 0 then
            if fuelExhIntervalCounter > fuelExhInterval then
                fuelExhState = 0
            else
                fuelExhIntervalCounter = fuelExhIntervalCounter + 0.1
            end
        end
    end
end
