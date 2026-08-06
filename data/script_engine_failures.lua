-- Engine failure simulation: spark plug, fuel pump, valve, and oil pressure failures.
-- Also handles in-pit fuel pump repair.

require "script_car_parameters"

-- Shared failure state (globals, reset by setupBits/resetCar in script.lua)
sparkPlugFailed = false
sparkPlugRepairInProgress = false
sparkPlugRoadsideRepairInProgress = false
sparkPlugPitTimer = 0
sparkPlugRoadsideTimer = 0
sparkPlugRoadsideChangedCount = 0
fuelPumpFailed = false
valveFailed = false
oilPressureFailed = false

-- Valve failure state
valveFailureMinDamage = thisCar.engineLifeLeft
valveFailureDamage = valveFailureMinDamage
-- Oil pressure failure state
oilPressureMinDamage = thisCar.engineLifeLeft
oilPressureFailureDamage = oilPressureMinDamage

-- Module-local failure state
local fuelPumpFailureCooldown = 0
local fuelPumpFailureDuration = 0
local fuelPumpCutoffActive = false
local valveWarning = false
local oilPressureWarning = false
local oilPressureWarning2 = false
local cvrPitCrewRoadsideSparkPlugService = false

local sparkPlugFouled = {}

local function getSparkPlugCylinderCountSafe()
    return math.max(1, math.floor(tonumber(sparkPlugCylinderCount) or 1))
end

local function getSparkPlugPerCylinderSafe()
    return math.max(1, math.floor(tonumber(sparkPlugPerCylinder) or 1))
end

function getSparkPlugTotalCount()
    return getSparkPlugCylinderCountSafe() * getSparkPlugPerCylinderSafe()
end

local function ensureSparkPlugState()
    local totalPlugCount = getSparkPlugTotalCount()
    for i = 1, totalPlugCount do
        if sparkPlugFouled[i] == nil then
            sparkPlugFouled[i] = false
        end
    end
    for i = totalPlugCount + 1, #sparkPlugFouled do
        sparkPlugFouled[i] = nil
    end
end

function getFouledSparkPlugCount()
    ensureSparkPlugState()
    local fouledCount = 0
    for i = 1, getSparkPlugTotalCount() do
        if sparkPlugFouled[i] then
            fouledCount = fouledCount + 1
        end
    end
    return fouledCount
end

function getDeadSparkCylinderCount()
    ensureSparkPlugState()
    local cylinderCount = getSparkPlugCylinderCountSafe()
    local plugsPerCylinder = getSparkPlugPerCylinderSafe()
    local deadCylinderCount = 0

    for cylinder = 1, cylinderCount do
        local allPlugsFouled = true
        local firstPlugIndex = ((cylinder - 1) * plugsPerCylinder) + 1
        for plug = 0, plugsPerCylinder - 1 do
            if not sparkPlugFouled[firstPlugIndex + plug] then
                allPlugsFouled = false
                break
            end
        end
        if allPlugsFouled then
            deadCylinderCount = deadCylinderCount + 1
        end
    end

    return deadCylinderCount
end

function getSparkPlugPowerLossFraction()
    return math.clamp(getFouledSparkPlugCount() / getSparkPlugTotalCount(), 0, 0.95)
end

local function updateSparkPlugFailedState()
    sparkPlugFailed = getFouledSparkPlugCount() > 0
end

function resetSparkPlugFailures()
    ensureSparkPlugState()
    for i = 1, getSparkPlugTotalCount() do
        sparkPlugFouled[i] = false
    end
    sparkPlugFailed = false
    sparkPlugRepairInProgress = false
    sparkPlugRoadsideRepairInProgress = false
    sparkPlugPitTimer = 0
    sparkPlugRoadsideTimer = 0
    sparkPlugRoadsideChangedCount = 0
end

local function foulRandomHealthySparkPlug()
    ensureSparkPlugState()
    local healthyPlugIndexes = {}
    for i = 1, getSparkPlugTotalCount() do
        if not sparkPlugFouled[i] then
            healthyPlugIndexes[#healthyPlugIndexes + 1] = i
        end
    end

    if #healthyPlugIndexes == 0 then
        return false
    end

    local failedPlugIndex = healthyPlugIndexes[math.random(1, #healthyPlugIndexes)]
    sparkPlugFouled[failedPlugIndex] = true
    updateSparkPlugFailedState()
    return true
end

function forceSparkPlugFailureForTesting()
    return foulRandomHealthySparkPlug()
end

local function repairOneFouledSparkPlug()
    ensureSparkPlugState()
    for i = 1, getSparkPlugTotalCount() do
        if sparkPlugFouled[i] then
            sparkPlugFouled[i] = false
            updateSparkPlugFailedState()
            return true
        end
    end

    updateSparkPlugFailedState()
    return false
end

local function getSparkPlugRepairTime(firstPlugSeconds, additionalPlugSeconds)
    local fouledCount = getFouledSparkPlugCount()
    if fouledCount <= 0 then
        return 0
    end
    return firstPlugSeconds + math.max(0, fouledCount - 1) * additionalPlugSeconds
end

function updateSparkPlugPowerLoss()
    local fouledCount = getFouledSparkPlugCount()
    if fouledCount <= 0 then
        return
    end

    local lossFraction = getSparkPlugPowerLossFraction()
    local misfirePulse = 0
    if math.random() < math.min(0.65, lossFraction * 2.0) then
        misfirePulse = math.random() * lossFraction * 0.35
    end

    acCarPhysics.gas = (acCarPhysics.gas or 0) * math.max(0.03, 1 - lossFraction - misfirePulse)
end

function sparkPlugFailure()
    ensureSparkPlugState()
    local fouledCount = getFouledSparkPlugCount()
    local totalPlugCount = getSparkPlugTotalCount()
    if fouledCount >= totalPlugCount then
        return
    end

    local cascadeRisk = tonumber(sparkPlugCascadeRiskPerFouledPlug) or 0.25
    local roughRunningFactor = 1 + fouledCount * cascadeRisk
    local effectiveFailureRate = math.max(
        sparkPlugFailureRateMinimumValue,
        math.floor(sparkPlugFailureRate / roughRunningFactor + 0.5))

    if math.random(1, effectiveFailureRate) == 1 then
        if foulRandomHealthySparkPlug() then
            local currentFouledCount = getFouledSparkPlugCount()
            local deadCylinderCount = getDeadSparkCylinderCount()
            overheadMessageQueue(
                "Spark plug fouled",
                string.format("%d/%d plugs fouled, %d cylinders dead", currentFouledCount, getSparkPlugTotalCount(), deadCylinderCount),
                10)
            logDebug("<FLR>Spark Plug Fail, rate: ", effectiveFailureRate, " fouled: ", currentFouledCount, true)
        end
    end

    printDebug("Spark Plug Failure", string.format(
        "Status: %s | Fouled: %d/%d | Dead cylinders: %d | Power loss: %.1f%%",
        tostring(sparkPlugFailed),
        getFouledSparkPlugCount(),
        getSparkPlugTotalCount(),
        getDeadSparkCylinderCount(),
        getSparkPlugPowerLossFraction() * 100))
end --end of spark plug failure

function sparkPlugPitRepair(dt)
    if isCarInPits and isPitRepairQueueCurrent("sparkPlugs") and getFouledSparkPlugCount() <= 0 then
        completePitRepairQueueItem("sparkPlugs")
        return
    end

    if isCarInPits and getFouledSparkPlugCount() > 0 and (sparkPlugRepairInProgress or isPitRepairQueueCurrent("sparkPlugs")) then
        if isPitRepairQueueCurrent("sparkPlugs") and not sparkPlugRepairInProgress then
            sparkPlugRepairInProgress = true
            sparkPlugPitTimer = 0
            overheadMessageQueue("Spark plug service", "Service started. Hold position until done", 3, true)
        end

        if sparkPlugRepairInProgress then
            local repairTime = getSparkPlugRepairTime(
                sparkPlugPitChangeFirstPlugSeconds,
                sparkPlugPitChangeAdditionalPlugSeconds)
            sparkPlugPitTimer = sparkPlugPitTimer + dt
            overheadMessageQueue("Spark plug service", string.format(
                "Progress: %d%%",
                math.floor(math.min(100, (sparkPlugPitTimer / math.max(0.1, repairTime)) * 100))), 1, true)

            if sparkPlugPitTimer >= repairTime then
                resetSparkPlugFailures()
                sparkPlugFailureRate = sparkPlugFailureRateInitialValue
                sparkPlugFailureRateBase = sparkPlugFailureRateInitialValue
                overheadMessageQueue("Spark plug service", "Service complete", 3, true)
                completePitRepairQueueItem("sparkPlugs")
            end
        end
    else
        sparkPlugRepairInProgress = false
        sparkPlugPitTimer = 0
    end
end

function sparkPlugRoadsideRepair(dt)
    if getFouledSparkPlugCount() <= 0 or isCarInPits then
        if cvrPitCrewRoadsideSparkPlugService and completeCVRPitCrewRoadsideRepairService then
            completeCVRPitCrewRoadsideRepairService(CVR_ROADSIDE_REPAIR_SPARK_PLUGS)
        end
        cvrPitCrewRoadsideSparkPlugService = false
        sparkPlugRoadsideRepairInProgress = false
        sparkPlugRoadsideTimer = 0
        sparkPlugRoadsideChangedCount = 0
        return
    end

    local speedKmh = thisCar.speedKmh or 0
    local stoppedWithHandbrake = speedKmh < 1 and (thisCar.handbrake or 0) > 0.9
    local appRoadsideRequest = isCVRPitCrewRoadsideRepairRequested
        and isCVRPitCrewRoadsideRepairRequested(CVR_ROADSIDE_REPAIR_SPARK_PLUGS)
    local otherRepairActive = tyreChangeInProgress or isRepairingBelt or fuelPumpRepairInProgress
        or gearboxRepairInProgress or oilPitRefillInProgress or sparkPlugRepairInProgress

    if sparkPlugRoadsideRepairInProgress and speedKmh > 2 then
        sparkPlugRoadsideRepairInProgress = false
        sparkPlugRoadsideTimer = 0
        sparkPlugRoadsideChangedCount = 0
        if cvrPitCrewRoadsideSparkPlugService then
            cvrPitCrewRoadsideSparkPlugService = false
            if cancelCVRPitCrewRoadsideService then
                cancelCVRPitCrewRoadsideService()
            end
        end
        return
    end

    if (stoppedWithHandbrake or appRoadsideRequest or sparkPlugRoadsideRepairInProgress) and not otherRepairActive then
        sparkPlugRoadsideTimer = sparkPlugRoadsideTimer + dt
        local plugsLeft = getFouledSparkPlugCount()
        local nextPlugThreshold = sparkPlugRoadsideReactionTime
            + sparkPlugRoadsideChangeFirstPlugSeconds
            + sparkPlugRoadsideChangedCount * sparkPlugRoadsideChangeAdditionalPlugSeconds
        local fullRepairTime = nextPlugThreshold
            + math.max(0, plugsLeft - 1) * sparkPlugRoadsideChangeAdditionalPlugSeconds

        if sparkPlugRoadsideTimer >= sparkPlugRoadsideReactionTime then
            if appRoadsideRequest and not cvrPitCrewRoadsideSparkPlugService then
                cvrPitCrewRoadsideSparkPlugService = true
                if beginCVRPitCrewRoadsideService then
                    beginCVRPitCrewRoadsideService()
                end
            end
            sparkPlugRoadsideRepairInProgress = true
            acCarPhysics.gas = 0
            acCarPhysics.brake = 1
            acCarPhysics.handbrake = 1
            ac.setEngineRPM(0)
            overheadMessageQueue("SPARK PLUGS", string.format(
                "Changing plugs: %d%%",
                math.floor(math.min(100, (sparkPlugRoadsideTimer / math.max(0.1, fullRepairTime)) * 100))),
                1,
                true)
        end

        if sparkPlugRoadsideTimer >= nextPlugThreshold then
            if repairOneFouledSparkPlug() then
                sparkPlugRoadsideChangedCount = sparkPlugRoadsideChangedCount + 1
                plugsLeft = getFouledSparkPlugCount()
                overheadMessageQueue(
                    "Spark Plug Changed",
                    string.format("%d fouled plugs left", plugsLeft),
                    3)
            end

            if plugsLeft <= 0 then
                sparkPlugRoadsideRepairInProgress = false
                sparkPlugRoadsideTimer = 0
                sparkPlugRoadsideChangedCount = 0
                sparkPlugFailureRate = sparkPlugFailureRateInitialValue
                sparkPlugFailureRateBase = sparkPlugFailureRateInitialValue
                overheadMessageQueue("Spark Plugs Changed", "Roadside plug change complete", 3)
                if cvrPitCrewRoadsideSparkPlugService then
                    cvrPitCrewRoadsideSparkPlugService = false
                    if completeCVRPitCrewRoadsideRepairService then
                        completeCVRPitCrewRoadsideRepairService(CVR_ROADSIDE_REPAIR_SPARK_PLUGS)
                    end
                end
            end
        end
    else
        sparkPlugRoadsideRepairInProgress = false
        sparkPlugRoadsideTimer = 0
        sparkPlugRoadsideChangedCount = 0
    end
end

function fuelPumpFailureActivation()
    -- Cars using manual fuel tank pressurization do not rely on a mechanical
    -- fuel pump, so the old random fuel pump fault should not occur.
    if isManualFuelPressureDriverEnabled and isManualFuelPressureDriverEnabled() then
        fuelPumpFailed = false
        fuelPumpFailureCooldown = 0
        fuelPumpFailureDuration = 0
        fuelPumpCutoffActive = false
        return
    end

    -- Only check for activation if not already failed
    if not fuelPumpFailed then
        -- Roll for failure (every 2 seconds)
        if math.random(1, fuelPumpFailureRate) == 1 then
            fuelPumpFailed = true
            fuelPumpFailureDuration = math.random(1, 3)
            fuelPumpFailureCooldown = math.random(4, 7)
            overheadMessageQueue("Fuel Pump Failure", "Fuel flow disrupted!", 5)
            printDebug("Fuel Pump", "Failure activated!")
            logDebug("<FLR>Fuel Pump Fail, rate: ", fuelPumpFailureRate, true)
        end
    end
end

function fuelPumpFailure(dt)
    -- Manual fuel pressurization replaces the mechanical fuel pump. Fuel feed
    -- problems for these cars are handled by tank pressure in script_fuel.lua.
    if isManualFuelPressureDriverEnabled and isManualFuelPressureDriverEnabled() then
        fuelPumpFailed = false
        fuelPumpFailureCooldown = 0
        fuelPumpFailureDuration = 0
        fuelPumpCutoffActive = false
        return
    end

    -- Only process if failed state is active
    if not fuelPumpFailed then return end

    -- Failure behavior system (runs every tick)
    if fuelPumpCutoffActive then
        -- Active cutoff phase
        fuelPumpFailureDuration = fuelPumpFailureDuration - dt
        acCarPhysics.gas = 0  -- Hard throttle cutoff
        if fuelPumpFailureDuration <= 0 then
            fuelPumpCutoffActive = false
        end
    else
        -- Cooldown phase
        fuelPumpFailureCooldown = fuelPumpFailureCooldown - dt

        if fuelPumpFailureCooldown <= 0 then
            fuelPumpCutoffActive = true
            fuelPumpFailureDuration = math.random(1, 3)
            fuelPumpFailureCooldown = math.random(4, 7)
        end
    end

    -- Optional debug
    printDebug("Fuel Pump Behavior", string.format(
        "Cutoff: %s | Duration: %.1f | Cooldown: %.1f",
        tostring(fuelPumpCutoffActive),
        fuelPumpFailureDuration,
        fuelPumpFailureCooldown
    ))
end --end of fuel pump failure

--valve failure
--simply, if you roll unlucky, you get slapped with random engine damage between certain values.
--if you already have more damage, its skipped.
function valveFailure(dt)
    if not valveFailed then
        if math.random(1, valveFailureRate) == 1 then
            valveFailureActive = true
            valveFailed = true
            overheadMessageQueue("Valve problems", "Early stage valve issues detected", 5)
            logDebug("<FLR>Valve Fail, rate: ", valveFailureRate, true)
        end
        return
    end

    if valveFailureActive then
        -- RPM-based progression control
        if acCarPhysics.rpm > 0 and not totalMeltdown then
            valveFailureMinDamage = acCarPhysics.engineLifeLeft
            -- Calculate RPM factor (0-2.0 range)
            local rpmFactor = math.clamp(acCarPhysics.rpm / valveReferenceRPM, 0.1, 2.0)

            -- Effective time accumulation
            valveFailureElapsed = valveFailureElapsed + (dt * rpmFactor)

            -- Calculate progression (0-1)
            local progression = math.clamp(valveFailureElapsed / valveFailureBaseTime, 0, 1)

            -- Non-linear damage curve
            local damageProgression = progression^1.3  -- Faster initial degradation
            valveFailureDamage = math.lerp(valveFailureMinDamage, valveFailureMaxDamage, damageProgression)

            -- Apply damage if engine still has life
            if acCarPhysics.engineLifeLeft > valveFailureDamage then
                ac.setEngineLifeLeft(valveFailureDamage)
            end

            -- Progressive warnings
            if progression > 0.8 and not valveWarning then
                overheadMessageQueue("CRITICAL VALVE FAILURE", "Immediate pit stop required!", 10)
                valveWarning = true
            elseif progression > 0.5 then
                overheadMessageQueue("Severe valve damage", "Power loss increasing significantly", 5)
            end

            -- Final failure state
            if progression >= 1.0 then
                valveFailureActive = false
                ac.setEngineLifeLeft(valveFailureMaxDamage)
                overheadMessageQueue("Total Valve Failure", "Engine no longer operational", 0)
            end
        else
            -- Pause progression when engine is off/stalled
            overheadMessageQueue("Valve Damage Halted", "Engine shutdown paused deterioration", 2)
        end
    end

end --end of valve failure

-- Oil pressure failure.
-- The random failure roll still comes from the original failure-rate system.
-- When it happens, it damages the oil pump; the oil system then decides how
-- much pressure is lost and whether engine damage starts.
function oilPressureFailure(dt)
    if not oilPressureFailed then
        if isManualOilPumpDriverEnabled and isManualOilPumpDriverEnabled() then
            return
        end

        if math.random(1, oilPressureFailureRate) == 1 then
            oilPressureFailed = true
            oilPressureFailureActive = false
            if damageOilPressurePump then
                damageOilPressurePump()
            end
            overheadMessageQueue("Oil pressure problems", "Early stage oil pressure issues detected", 5)
            logDebug("<FLR>Oil Pressure Fail, rate: ", oilPressureFailureRate, true)
        end
        return
    end

    if oilPressureDamageActive then
        oilPressureFailureActive = true
        oilPressureFailed = true
    elseif oilPressureSystemCanLubricateEngine and oilPressureSystemCanLubricateEngine() then
        -- The pump can be damaged while pressure is still acceptable. In that
        -- case, keep the pump fault latched but pause engine damage progression.
        oilPressureFailureActive = false
        oilPressureFailureElapsed = math.max(0, oilPressureFailureElapsed - dt * oilPressureRecoveryGraceMultiplier)
        return
    end

    if oilPressureFailureActive then
        -- RPM-based progression control
        if acCarPhysics.rpm > 0 and not totalMeltdown then
            oilPressureFailureMinDamage = acCarPhysics.engineLifeLeft
            -- Calculate RPM factor (0-2.0 range)
            local oilPressurerpmFactor = math.clamp(acCarPhysics.rpm / oilPressureReferenceRPM, 0.1, 2.0)

            -- Effective time accumulation
            oilPressureFailureElapsed = oilPressureFailureElapsed + (dt * oilPressurerpmFactor)

            -- Calculate progression (0-1)
            local oilPressureProgression = math.clamp(oilPressureFailureElapsed / oilPressureFailureBaseTime, 0, 1)

            -- Non-linear damage curve
            local oilPressureDamageProgression = oilPressureProgression^1.3  -- Faster initial degradation
            oilPressureFailureDamage = math.lerp(oilPressureFailureMinDamage, oilPressureFailureMaxDamage, oilPressureDamageProgression)

            -- Apply damage if engine still has life
            if acCarPhysics.engineLifeLeft > oilPressureFailureDamage then
                ac.setEngineLifeLeft(oilPressureFailureDamage)
            end

            -- Progressive warnings
            if oilPressureProgression > 0.8 and not oilPressureWarning then
                overheadMessageQueue("CRITICAL OIL PRESSURE", "Immediate pit stop required!", 10)
                oilPressureWarning = true
            elseif oilPressureProgression > 0.5 and not oilPressureWarning2 then
                overheadMessageQueue("Really low oil pressure", "Power loss and engine overheating increasing significantly", 5)
                oilPressureWarning2 = true
            end

            -- Final failure state
            if oilPressureProgression >= 1.0 then
                oilPressureFailureActive = false
                ac.setEngineLifeLeft(oilPressureFailureMaxDamage)
                overheadMessageQueue("Total oil pressure issue", "Engine no longer operational", 0)
            end
        else
            -- Pause progression when engine is off/stalled
            overheadMessageQueue("Engine stalled", "Cooling down", 2)
        end
    end

end --end of oil pressure failure

-- In-pit fuel pump repair routine. Call from update() when car is in pits.
function fuelPumpPitRepair(dt)
    if isManualFuelPressureDriverEnabled and isManualFuelPressureDriverEnabled() then
        fuelPumpFailed = false
        fuelPumpRepairInProgress = false
        fuelPumpPitTimer = 0
        return
    end

    if isCarInPits and fuelPumpFailed and (fuelPumpRepairInProgress or isPitRepairQueueCurrent("fuelPump")) then
        if isPitRepairQueueCurrent("fuelPump") and not fuelPumpRepairInProgress then
            fuelPumpRepairInProgress = true
            fuelPumpPitTimer = 0  -- Reset timer when repair starts
            overheadMessageQueue("Fuel pump repair", "Service started. Hold position until done", 3, true)
            printDebug("Fuel Pump Repair", "Repair process started")
        end

        -- If repair is in progress, count time
        if fuelPumpRepairInProgress then
            fuelPumpPitTimer = fuelPumpPitTimer + dt

            overheadMessageQueue("Fuel pump repair",
                    string.format("Progress: %d%%",
                    math.floor(math.min(100, (fuelPumpPitTimer / math.max(0.1, fuelPumpRepairTime)) * 100))), 1, true)
            printDebug("Fuel Pump Repair Progress", string.format("%.1f sec left", fuelPumpRepairTime - fuelPumpPitTimer))

            -- When repair time has passed, complete the repair
            if fuelPumpPitTimer >= fuelPumpRepairTime then
                fuelPumpFailed = false
                fuelPumpRepairInProgress = false
                fuelPumpPitTimer = 0
                fuelPumpRepairTime = math.random(30, 180)

                -- Reset failure rates to initial values, as the pump has been fixed.
                fuelPumpFailureRate = fuelPumpFailureRateInitialValue
                fuelPumpFailureRateBase = fuelPumpFailureRateInitialValue

                overheadMessageQueue("Fuel pump repair", "Service complete", 3, true)
                printDebug("Fuel Pump Repair", "Repair complete!")
                completePitRepairQueueItem("fuelPump")
            end
        end
    else
        -- Reset if car leaves pits
        fuelPumpRepairInProgress = false
        fuelPumpPitTimer = 0
    end
end
