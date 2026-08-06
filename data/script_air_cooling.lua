-- Air-cooled fan belt and fan/shroud fault model.

require "script_car_parameters"

AIR_COOLING_STATUS_OK = 0
AIR_COOLING_STATUS_BELT_SLIPPING = 1
AIR_COOLING_STATUS_BELT_BROKEN = 2
AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED = 3

airCoolingStatus = AIR_COOLING_STATUS_OK
airCoolingBeltStress = 0
airCoolingBeltSlipCoolingLoss = 0
airCoolingBeltSlipGeneratorLoss = 0
airCoolingBeltBrokenCoolingLoss = 0
airCoolingFanShroudCoolingLoss = 0
airCoolingPitRepairInProgress = false
airCoolingRoadsideRepairInProgress = false
airCoolingRepairTimer = 0
airCoolingRepairTime = 0

local updateTimer = 0
local warningCooldown = 0
local previousFanShroudDamage = 0
local cvrPitCrewRoadsideAirCoolingService = false
local FAN_DRIVE_SHARED_BELT = AIR_COOLING_FAN_DRIVE_SHARED_BELT or 1
local FAN_DRIVE_SEPARATE_BELT = AIR_COOLING_FAN_DRIVE_SEPARATE_BELT or 2
local FAN_DRIVE_GEAR_DRIVEN = AIR_COOLING_FAN_DRIVE_GEAR_DRIVEN or 3
local FAN_DRIVE_DIRECT_DRIVEN = AIR_COOLING_FAN_DRIVE_DIRECT_DRIVEN or 4
local FAN_DRIVE_NONE = AIR_COOLING_FAN_DRIVE_NONE or 5

local function randomBetween(minimumValue, maximumValue)
    return minimumValue + math.random() * (maximumValue - minimumValue)
end

local function isAirCoolingActive()
    return isAirCoolingSystemEnabled and isAirCoolingSystemEnabled()
end

function getAirCoolingFanDriveType()
    if not isAirCoolingActive() then
        return 0
    end

    -- Keep old car parameter files functional. Their false flag disabled only
    -- the fault model, not the RPM-driven cooling contribution.
    if airCoolingFanDriveType == nil and airCoolingFanBeltEnabled == false then
        return FAN_DRIVE_GEAR_DRIVEN
    end

    local driveType = tonumber(airCoolingFanDriveType) or FAN_DRIVE_SHARED_BELT
    if driveType < FAN_DRIVE_SHARED_BELT or driveType > FAN_DRIVE_NONE then
        return FAN_DRIVE_SHARED_BELT
    end
    return math.floor(driveType + 0.5)
end

function airCoolingUsesFanBelt()
    local driveType = getAirCoolingFanDriveType()
    return driveType == FAN_DRIVE_SHARED_BELT
        or driveType == FAN_DRIVE_SEPARATE_BELT
end

function airCoolingSharesGeneratorBelt()
    return getAirCoolingFanDriveType() == FAN_DRIVE_SHARED_BELT
end

function airCoolingHasMechanicalFan()
    local driveType = getAirCoolingFanDriveType()
    return driveType == FAN_DRIVE_SHARED_BELT
        or driveType == FAN_DRIVE_SEPARATE_BELT
        or driveType == FAN_DRIVE_GEAR_DRIVEN
        or driveType == FAN_DRIVE_DIRECT_DRIVEN
end

function getAirCoolingPitRepairLabel()
    local driveType = getAirCoolingFanDriveType()
    if driveType == FAN_DRIVE_SHARED_BELT then
        return "Fan/charging belt"
    end
    if driveType == FAN_DRIVE_SEPARATE_BELT then
        return "Fan belt"
    end
    if driveType == FAN_DRIVE_GEAR_DRIVEN
            or driveType == FAN_DRIVE_DIRECT_DRIVEN then
        return "Cooling fan"
    end
    return nil
end

function getAirCoolingFanDriveDescription()
    return ({
        [FAN_DRIVE_SHARED_BELT] = "Shared belt",
        [FAN_DRIVE_SEPARATE_BELT] = "Separate belts",
        [FAN_DRIVE_GEAR_DRIVEN] = "Gear driven",
        [FAN_DRIVE_DIRECT_DRIVEN] = "Direct driven",
        [FAN_DRIVE_NONE] = "Ram air only",
    })[getAirCoolingFanDriveType()] or "N/A"
end

local function airCoolingFaultModelAvailable()
    local legacyFaultModelDisabled = airCoolingFanDriveType == nil and airCoolingFanBeltEnabled == false
    return not legacyFaultModelDisabled and isAirCoolingActive() and airCoolingHasMechanicalFan()
end

local function beginBeltSlip()
    if not airCoolingUsesFanBelt() or airCoolingStatus ~= AIR_COOLING_STATUS_OK then
        return
    end

    airCoolingStatus = AIR_COOLING_STATUS_BELT_SLIPPING
    airCoolingBeltSlipCoolingLoss = randomBetween(airCoolingBeltSlipCoolingLossMin, airCoolingBeltSlipCoolingLossMax)
    if airCoolingSharesGeneratorBelt() then
        airCoolingBeltSlipGeneratorLoss = randomBetween(airCoolingBeltSlipGeneratorLossMin, airCoolingBeltSlipGeneratorLossMax)
    end
    warningCooldown = 20
    overheadMessageQueue("Fan belt slipping",
        airCoolingSharesGeneratorBelt() and "Cooling fan and generator output are reduced" or "Cooling fan output is reduced",
        4)
end

local function beginBeltBroken(reason)
    if not airCoolingUsesFanBelt() or airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN then
        return
    end

    airCoolingStatus = AIR_COOLING_STATUS_BELT_BROKEN
    airCoolingBeltBrokenCoolingLoss = randomBetween(airCoolingBeltBrokenCoolingLossMin, airCoolingBeltBrokenCoolingLossMax)
    airCoolingBeltSlipCoolingLoss = 0
    airCoolingBeltSlipGeneratorLoss = 0
    if airCoolingSharesGeneratorBelt() then
        alternatorOK = false
    end
    airCoolingRoadsideRepairInProgress = false
    airCoolingPitRepairInProgress = false
    airCoolingRepairTimer = 0
    airCoolingRepairTime = 0
    overheadMessageQueue("Fan belt broken",
        reason or (airCoolingSharesGeneratorBelt() and "Cooling fan and generator have failed" or "Cooling fan has failed"),
        5)
end

local function beginFanShroudDamage()
    if airCoolingStatus == AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED
            or airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN then
        return
    end

    airCoolingStatus = AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED
    airCoolingFanShroudCoolingLoss = randomBetween(airCoolingFanShroudDamageCoolingLossMin, airCoolingFanShroudDamageCoolingLossMax)
    airCoolingRoadsideRepairInProgress = false
    airCoolingPitRepairInProgress = false
    airCoolingRepairTimer = 0
    airCoolingRepairTime = 0
    overheadMessageQueue("Cooling fan damage", "Body damage has reduced fan airflow. Pit repair required.", 4)
end

local function clearAirCoolingFault()
    local restoreGenerator = airCoolingSharesGeneratorBelt()
        and airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN
    airCoolingStatus = AIR_COOLING_STATUS_OK
    airCoolingBeltStress = 0
    airCoolingBeltSlipCoolingLoss = 0
    airCoolingBeltSlipGeneratorLoss = 0
    airCoolingBeltBrokenCoolingLoss = 0
    airCoolingFanShroudCoolingLoss = 0
    airCoolingPitRepairInProgress = false
    airCoolingRoadsideRepairInProgress = false
    airCoolingRepairTimer = 0
    airCoolingRepairTime = 0
    if restoreGenerator then
        alternatorOK = true
        alternatorHealth = math.max(alternatorHealth or 0, 0.85)
    end
end

local function getFanShroudDamage()
    -- AC side damage covers the full length of a car. Keep the fan/shroud
    -- impact zones explicit so a damaged front wing does not harm a rear fan.
    local sides = airCoolingFanShroudDamageSides or {false, true, true, true}
    local totalDamage = 0
    local selectedSideCount = 0
    for damageIndex = 0, 3 do
        if sides[damageIndex + 1] then
            totalDamage = totalDamage + (thisCar.damage[damageIndex] or 0)
            selectedSideCount = selectedSideCount + 1
        end
    end

    return selectedSideCount > 0 and totalDamage / selectedSideCount or 0
end

local function updateStress(dt)
    local rpm = acCarPhysics.rpm or thisCar.rpm or 0
    local rpmLimit = acCarPhysics.rpmLimit or engineDamageRPMThreshold or 6500
    local rpmFactor = math.clamp(rpm / math.max(rpmLimit, 1), 0, 1.25)
    local highRpmStress = math.max(0, rpmFactor - 0.82) / 0.30
    local tempStress = math.max(0, (engineTemp or 0) - 92) / 28
    local overrevStress = (getOverrevvingState and getOverrevvingState() or 0) * 0.7
    local oilStress = (oilTankLeakageDamage or fuelLeakageDamage) and 0.7 or 0
    local fanShroudDamage = getFanShroudDamage()
    local rearDamageStress = math.max(0, fanShroudDamage - airCoolingBeltRearDamageThreshold) / 65

    local stressInput = highRpmStress + tempStress + overrevStress + oilStress + rearDamageStress
    if airCoolingUsesFanBelt() and stressInput > 0 then
        airCoolingBeltStress = math.min(
            airCoolingBeltStress + stressInput * airCoolingBeltStressBuildPerSecond * dt,
            airCoolingBeltStressBrokenThreshold + 0.75)
    elseif airCoolingUsesFanBelt() then
        airCoolingBeltStress = math.max(0, airCoolingBeltStress - airCoolingBeltStressRecoveryPerSecond * dt)
    end

    if fanShroudDamage > airCoolingBeltRearDamageThreshold and fanShroudDamage > previousFanShroudDamage + 8 then
        if airCoolingUsesFanBelt() and fanShroudDamage >= airCoolingBeltRearDamageBrokenThreshold and math.random() < 0.35 then
            beginBeltBroken("Body damage has thrown the fan belt")
        elseif math.random() < 0.45 then
            beginFanShroudDamage()
        end
    end
    previousFanShroudDamage = fanShroudDamage

    updateTimer = updateTimer + dt
    if updateTimer < 1 then
        return
    end
    updateTimer = 0

    if airCoolingUsesFanBelt() and airCoolingStatus == AIR_COOLING_STATUS_OK
            and airCoolingBeltStress >= airCoolingBeltStressSlipThreshold then
        local slipChance = math.clamp((airCoolingBeltStress - airCoolingBeltStressSlipThreshold) * 0.035, 0, 0.04)
        if math.random() < slipChance then
            beginBeltSlip()
        end
    elseif airCoolingUsesFanBelt() and airCoolingStatus == AIR_COOLING_STATUS_BELT_SLIPPING then
        local breakChance = math.clamp((airCoolingBeltStress - airCoolingBeltStressBrokenThreshold) * 0.030, 0, 0.05)
        if (airCoolingBeltStress >= airCoolingBeltStressBrokenThreshold and math.random() < breakChance)
                or (getOverrevvingState and getOverrevvingState() == 2 and math.random() < 0.012) then
            beginBeltBroken("The slipping fan belt has been thrown")
        elseif warningCooldown <= 0 then
            overheadMessageQueue("Fan belt slipping", "Ease off or repair the belt before it fails", 4, true)
            warningCooldown = 20
        end
    end
end

local function startRepair(isPitRepair)
    airCoolingRepairTimer = 0
    airCoolingPitRepairInProgress = isPitRepair
    airCoolingRoadsideRepairInProgress = not isPitRepair

    if isPitRepair then
        if airCoolingStatus == AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED then
            airCoolingRepairTime = math.random(airCoolingFanShroudPitRepairTimeMinSeconds, airCoolingFanShroudPitRepairTimeMaxSeconds)
            overheadMessageQueue("Cooling repair", "Fan/shroud service started. Hold position until done", 3, true)
        else
            airCoolingRepairTime = math.random(airCoolingBeltPitRepairTimeMinSeconds, airCoolingBeltPitRepairTimeMaxSeconds)
            overheadMessageQueue("Cooling repair", "Fan belt service started. Hold position until done", 3, true)
        end
    else
        airCoolingRepairTime = math.random(airCoolingBeltRoadsideRepairTimeMinSeconds, airCoolingBeltRoadsideRepairTimeMaxSeconds)
        overheadMessageQueue("Cooling repair", "Roadside belt service started. Hold position until done", 4, true)
    end
end

local function updatePitRepair(dt)
    if not isCarInPits or not isPitRepairQueueCurrent or not isPitRepairQueueCurrent("airCooling") then
        if airCoolingPitRepairInProgress then
            airCoolingPitRepairInProgress = false
            airCoolingRepairTimer = 0
        end
        return
    end

    if airCoolingStatus == AIR_COOLING_STATUS_OK then
        completePitRepairQueueItem("airCooling")
        return
    end

    if not airCoolingPitRepairInProgress then
        startRepair(true)
    end

    airCoolingRepairTimer = airCoolingRepairTimer + dt
    overheadMessageQueue("Cooling repair", string.format("Progress: %d%%", math.floor((airCoolingRepairTimer / airCoolingRepairTime) * 100)), 1, true)

    if airCoolingRepairTimer >= airCoolingRepairTime then
        clearAirCoolingFault()
        overheadMessageQueue("Cooling repair", "Service complete", 3, true)
        completePitRepairQueueItem("airCooling")
    end
end

local function updateRoadsideRepair(dt)
    if isCarInPits or airCoolingSharesGeneratorBelt() or not airCoolingUsesFanBelt()
            or airCoolingStatus == AIR_COOLING_STATUS_OK
            or airCoolingStatus == AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED then
        airCoolingRoadsideRepairInProgress = false
        return
    end

    local speedKmh = thisCar.speedKmh or 0
    local appRoadsideRequest = isCVRPitCrewRoadsideRepairRequested
        and isCVRPitCrewRoadsideRepairRequested(CVR_ROADSIDE_REPAIR_AIR_COOLING)
    local stoppedWithHandbrake = speedKmh < 1 and (thisCar.handbrake or 0) > 0.9
    if not (stoppedWithHandbrake or appRoadsideRequest or airCoolingRoadsideRepairInProgress) or tyreChangeInProgress then
        if airCoolingRoadsideRepairInProgress and (thisCar.speedKmh or 0) > 2 then
            airCoolingRoadsideRepairInProgress = false
            airCoolingRepairTimer = 0
            airCoolingRepairTime = 0
            if cvrPitCrewRoadsideAirCoolingService then
                cvrPitCrewRoadsideAirCoolingService = false
                if cancelCVRPitCrewRoadsideService then
                    cancelCVRPitCrewRoadsideService()
                end
            end
        end
        return
    end

    if not airCoolingRoadsideRepairInProgress then
        if appRoadsideRequest then
            cvrPitCrewRoadsideAirCoolingService = true
            if beginCVRPitCrewRoadsideService then
                beginCVRPitCrewRoadsideService()
            end
        end
        startRepair(false)
    end

    acCarPhysics.gas = 0
    acCarPhysics.brake = 1
    acCarPhysics.handbrake = 1
    ac.setEngineRPM(0)

    airCoolingRepairTimer = airCoolingRepairTimer + dt
    overheadMessageQueue("Cooling repair", string.format("Progress: %d%%", math.floor((airCoolingRepairTimer / airCoolingRepairTime) * 100)), 1, true)

    if airCoolingRepairTimer >= airCoolingRepairTime then
        clearAirCoolingFault()
        overheadMessageQueue("Cooling repair", "Service complete", 3, true)
        if cvrPitCrewRoadsideAirCoolingService then
            cvrPitCrewRoadsideAirCoolingService = false
            if completeCVRPitCrewRoadsideRepairService then
                completeCVRPitCrewRoadsideRepairService(CVR_ROADSIDE_REPAIR_AIR_COOLING)
            end
        end
    end
end

function resetAirCoolingSystem(resetFault)
    cvrPitCrewRoadsideAirCoolingService = false
    if resetFault ~= false then
        clearAirCoolingFault()
    end
    previousFanShroudDamage = getFanShroudDamage()
    updateTimer = 0
    warningCooldown = 0
end

function needsAirCoolingPitRepair()
    if not airCoolingFaultModelAvailable() or airCoolingStatus == AIR_COOLING_STATUS_OK then
        return false
    end

    -- A shared fan/generator belt is serviced through the unified electrical
    -- repair. The cooling queue remains for fan or shroud damage only.
    return not airCoolingSharesGeneratorBelt()
        or airCoolingStatus == AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED
end

function isAirCoolingBeltBroken()
    return airCoolingUsesFanBelt() and airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN
end

function isAirCoolingSharedBeltBroken()
    return airCoolingSharesGeneratorBelt() and airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN
end

function needsAirCoolingSharedBeltService()
    return airCoolingSharesGeneratorBelt()
        and (airCoolingStatus == AIR_COOLING_STATUS_BELT_SLIPPING
            or airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN)
end

function repairAirCoolingSharedBelt()
    if not needsAirCoolingSharedBeltService() then
        return false
    end

    clearAirCoolingFault()
    return true
end

function forceAirCoolingBeltBroken(reason)
    if airCoolingSharesGeneratorBelt() then
        beginBeltBroken(reason)
        return true
    end

    return false
end

function getAirCoolingFanEfficiency()
    if not airCoolingFaultModelAvailable() then
        return 1
    end

    local loss = 0
    if airCoolingStatus == AIR_COOLING_STATUS_BELT_SLIPPING then
        loss = airCoolingBeltSlipCoolingLoss
    elseif airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN then
        loss = airCoolingBeltBrokenCoolingLoss
    elseif airCoolingStatus == AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED then
        loss = airCoolingFanShroudCoolingLoss
    end

    return math.clamp(1 - loss, 0.05, 1)
end

function getAirCoolingGeneratorEfficiency()
    if not airCoolingSharesGeneratorBelt() then
        return 1
    end

    if airCoolingStatus == AIR_COOLING_STATUS_BELT_SLIPPING then
        return math.clamp(1 - airCoolingBeltSlipGeneratorLoss, 0.35, 1)
    end

    if airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN then
        return 0
    end

    return 1
end

function getAirCoolingStatusDescription()
    if airCoolingStatus == AIR_COOLING_STATUS_BELT_SLIPPING then
        return "Belt slipping"
    end

    if airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN then
        return "Belt broken"
    end

    if airCoolingStatus == AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED then
        return "Fan/shroud damaged"
    end

    return "OK"
end

function updateAirCoolingSystem(dt)
    acCarPhysics.controllerInputs[73] = coolingSystemType
    acCarPhysics.controllerInputs[74] = airCoolingStatus
    acCarPhysics.controllerInputs[75] = getAirCoolingFanEfficiency()
    acCarPhysics.controllerInputs[76] = getAirCoolingGeneratorEfficiency()
    acCarPhysics.controllerInputs[77] = airCoolingBeltStress
    acCarPhysics.controllerInputs[78] = airCoolingPitRepairInProgress or airCoolingRoadsideRepairInProgress
    acCarPhysics.controllerInputs[79] = airCoolingRepairTime > 0 and math.clamp(airCoolingRepairTimer / airCoolingRepairTime, 0, 1) or 0
    acCarPhysics.controllerInputs[84] = getAirCoolingFanDriveType()

    if not airCoolingFaultModelAvailable() then
        return
    end

    if warningCooldown > 0 then
        warningCooldown = math.max(0, warningCooldown - dt)
    end

    updateStress(dt)
    updatePitRepair(dt)
    updateRoadsideRepair(dt)

end
