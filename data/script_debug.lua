-- Debug logging and test code.
-- logXxx functions are always compiled in (controlled by DEBUG_LOG_FILE flag).
-- selectFailureForTesting / setFailureForTesting are only used when TEST_CODE = true.
-- initFailureTypeCount() must be called from script.lua after all variables are initialised.

-- Module-local debug tracking state
local debugPrevExtraA = false
local debugPrevExtraB = false
local debugPrevExtraC = false
local debugPrevExtraD = false
local debugPrevExtraE = false
local debugPrevExtraF = false
local debugPrevExtraS = false
local debugPrevExtraT = false
local debugPrevInPits = false
local debugPrevHandbrake = false
local zeroToHundredState = {
    armed = true,
    running = false,
    timer = 0,
}

function updateZeroToHundredDebugTimer(dt)
    if not overheadMessageQueue then
        return
    end

    local speedKmh = acCarPhysics.speedKmh or thisCar.speedKmh or 0

    if speedKmh <= 0.5 then
        zeroToHundredState.armed = true
        zeroToHundredState.running = false
        zeroToHundredState.timer = 0
        return
    end

    if zeroToHundredState.armed and not zeroToHundredState.running and speedKmh >= 1.0 then
        zeroToHundredState.running = true
        zeroToHundredState.timer = 0
    end

    if zeroToHundredState.running then
        zeroToHundredState.timer = zeroToHundredState.timer + dt

        if speedKmh >= 100 then
            overheadMessageQueue("0-100 km/h", string.format("%.2f s", zeroToHundredState.timer), 4, true)
            logDebug("<DBG>0-100 km/h: ", string.format("%.2f s", zeroToHundredState.timer), true)
            zeroToHundredState.armed = false
            zeroToHundredState.running = false
        elseif speedKmh < 1.0 then
            zeroToHundredState.running = false
            zeroToHundredState.timer = 0
        end
    end
end

function logRates()
    logDebug("Rates, Spark plug: ", sparkPlugFailureRate)
    logDebug("Fuel pump: ", fuelPumpFailureRate)
    logDebug("Valves: ", valveFailureRate)
    logDebug("Oil pressure: ", oilPressureFailureRate)
    logDebug("Radiator cool coefficient: ", radiatorCoolCoefficient)
    if getAirCoolingStatusDescription then
        logDebug("Air cooling status: ", getAirCoolingStatusDescription(),
            ", fan eff: ", getAirCoolingFanEfficiency and getAirCoolingFanEfficiency() or 1,
            ", gen eff: ", getAirCoolingGeneratorEfficiency and getAirCoolingGeneratorEfficiency() or 1,
            ", stress: ", airCoolingBeltStress or 0)
    end
end

function logStaticInfo()
    logDebug("Track Name: ", ac.getTrackName())
    logDebug("Car Name: ", ac.getCarName(thisCar.index, true))
    local brakeDuctPercentageFront = ac.getScriptSetupValue("BRAKE_DUCT_F")()
    logDebug("BrakeDuct F: ", brakeDuctPercentageFront)
    local brakeDuctPercentageRear = ac.getScriptSetupValue("BRAKE_DUCT_R")()
    logDebug("BrakeDuct R: ", brakeDuctPercentageRear)
    local brakeDuctWingGainFront = getBrakeDuctWingGain(brakeDuctPercentageFront)
    logDebug("BrakeDuct Wing Gain F: ", brakeDuctWingGainFront)
    local brakeDuctWingGainRear = getBrakeDuctWingGain(brakeDuctPercentageRear)
    logDebug("BrakeDuct Wing Gain R: ", brakeDuctWingGainRear)
end

function logDebugDataToFile()
    logRates()

    local tyreName = ac.getTyresName(thisCar.index)
    local tyreTypeFactor = getTyreTypeFactor()
    logDebug("Tyre name: ", tyreName, ", factor: ", tyreTypeFactor)

    for i = 0, 3 do
        logDebug("Tyre " .. i .. " rate: ", tyrePunctureRates[i])
        logDebug("Tyre " .. i .. " vkm: ", thisCar.wheels[i].tyreVirtualKM)
    end

    logDebug("Engine / coolant temp: ", engineTemp, " / ", coolantTemp)
    if getAirCoolingStatusDescription then
        logDebug("Air cooling: status=", getAirCoolingStatusDescription(),
            ", fanEff=", getAirCoolingFanEfficiency and getAirCoolingFanEfficiency() or 1,
            ", genEff=", getAirCoolingGeneratorEfficiency and getAirCoolingGeneratorEfficiency() or 1,
            ", stress=", airCoolingBeltStress or 0,
            ", repairing=", tostring((airCoolingPitRepairInProgress or airCoolingRoadsideRepairInProgress) == true),
            ", repairProgress=", ((airCoolingRepairTime or 0) > 0 and math.clamp((airCoolingRepairTimer or 0) / airCoolingRepairTime, 0, 1) or 0))
    end
    logDebug("Engine life: ", acCarPhysics.engineLifeLeft)
    logDebug("Lap time: ", ac.lapTimeToString(thisCar.previousLapTimeMs))

    logDebug("Brake wear: ", brakeWearLevel)

    local turboCount = getTurboCount()
    for i = 0, turboCount-1 do
        logDebug("Turbo " .. i .. " fail rate: " .. getTurboFailureRate(i))
    end

    logDebug("Laps completed: ", thisCar.lapCount)
    logCumulativeRateChanges()
end

function logExtraButtonPresses()
    if thisCar.extraA and not debugPrevExtraA then
        logDebug("ExtraA pressed", true)
    end
    debugPrevExtraA = thisCar.extraA

    if thisCar.extraB and not debugPrevExtraB then
        logDebug("ExtraB pressed", true)
    end
    debugPrevExtraB = thisCar.extraB

    if thisCar.extraC and not debugPrevExtraC then
        logDebug("ExtraC pressed", true)
    end
    debugPrevExtraC = thisCar.extraC

    if thisCar.extraD and not debugPrevExtraD then
        logDebug("ExtraD pressed", true)
    end
    debugPrevExtraD = thisCar.extraD

    if thisCar.extraE and not debugPrevExtraE then
        logDebug("ExtraE pressed", true)
    end
    debugPrevExtraE = thisCar.extraE

    if thisCar.extraF and not debugPrevExtraF then
        logDebug("ExtraF pressed", true)
    end
    debugPrevExtraF = thisCar.extraF

    if thisCar.extraS and not debugPrevExtraS then
        logDebug("ExtraS pressed", true)
    end
    debugPrevExtraS = thisCar.extraS

    if thisCar.extraT and not debugPrevExtraT then
        logDebug("ExtraT pressed", true)
    end
    debugPrevExtraT = thisCar.extraT

    if thisCar.handbrake == 1 and not debugPrevHandbrake then
        logDebug("Handbrake engaged", true)
    end
    debugPrevHandbrake = (thisCar.handbrake == 1)
end

function logCarEnterAndLeavePits()
    if isCarInPits and not debugPrevInPits then
        logDebug("Enter pits", true)
    end
    if not isCarInPits and debugPrevInPits then
        logDebug("Exit pits", true)
        logStaticInfo()
    end

    debugPrevInPits = isCarInPits
end

----------------- Debug/testing code -----------------
--
-- While not in pits, press extra T to select a failure,
-- then press extra S until the failure occurs.
-- To clear all failures, select it using extra T, then
-- press extra S.

local failureTypes = {
    sparkPlugFailure = 1,
    fuelPumpFailure = 2,
    valveFailure = 3,
    oilPressureFailure = 4,
    gearFailure = 5,
    tyrePuncture_FL = 6,
    tyrePuncture_FR = 7,
    tyrePuncture_RL = 8,
    tyrePuncture_RR = 9,
    highSpeedLightCollision1 = 10,
    highSpeedLightCollision2 = 11,
    alternatorFailure = 12,
    clearAllFailures = 13
}

local failureDescriptions = {
    "Spark plug failure",
    "Fuel pump failure",
    "Valve failure",
    "Oil pressure failure",
    "Gear failure",
    "Tyre puncture front left",
    "Tyre puncture front right",
    "Tyre puncture rear left",
    "Tyre puncture rear right",
    "Test high speed collision - 150",
    "Test high speed collision - 750",
    "Alternator/electrical failure",
    "Clear all failures"
}

-- origXxx values are captured in initFailureTypeCount(), which is called from
-- script.lua after all variables are initialised (not at require/load time).
local origSparkPlugFailureRateBase
local origFuelPumpFailureRateBase
local origValveFailureRateBase
local origOilPressureFailureRateBase
local origGearFailureRate
local origBoostedGearFailureRate
local origTyrePunctureRate

local highSpeedCollisionDone = false
local failureTypeCount = 0
local selectedFailure = 0
local prevExtraSState = false
local prevExtraTState = false

function initFailureTypeCount()
    for _ in pairs(failureTypes) do
        failureTypeCount = failureTypeCount + 1
    end
    -- Capture original values now that all variables are initialised.
    origSparkPlugFailureRateBase = sparkPlugFailureRateBase
    origFuelPumpFailureRateBase = fuelPumpFailureRateBase
    origValveFailureRateBase = valveFailureRateBase
    origOilPressureFailureRateBase = oilPressureFailureRateBase
    origGearFailureRate = gearFailureRate
    origBoostedGearFailureRate = boostedGearFailureRate
    origTyrePunctureRate = tyrePunctureRate
end

-- These should not be included in release packages,
-- therefore calls to these functions MUST be behind
-- the TEST_CODE flag!
function selectFailureForTesting()
    if not isCarInPits and not thisCar.extraT and prevExtraTState then
        selectedFailure = selectedFailure + 1
        if selectedFailure > failureTypeCount then
            selectedFailure = 1
        end
        prevExtraTState = false
        printDebug("Selected failure type:", failureDescriptions[selectedFailure], true)
    end

    if thisCar.extraT then
        prevExtraTState = true
    else
        prevExtraTState = false
    end
end

local function getTestGearIndex()
    local currentGearIndex = getCurrentGearIndex()
    if currentGearIndex and currentGearIndex > 0 then
        return currentGearIndex
    end
    return 1
end

local function triggerSparkPlugFailureForTesting()
    if forceSparkPlugFailureForTesting then
        forceSparkPlugFailureForTesting()
    else
        sparkPlugFailed = true
    end
    overheadMessageQueue("TEST", "Spark plug fouling forced", 3, true)
    logDebug("<TEST>Spark plug failure forced", true)
end

local function triggerFuelPumpFailureForTesting()
    if isManualFuelPressureDriverEnabled and isManualFuelPressureDriverEnabled() then
        fuelPumpFailed = false
        overheadMessageQueue("TEST", "Fuel pump skipped: manual tank pressure enabled", 3, true)
        logDebug("<TEST>Fuel pump failure skipped, manual fuel pressurization enabled", true)
        return
    end

    fuelPumpFailed = true
    overheadMessageQueue("TEST", "Fuel pump failure forced", 3, true)
    logDebug("<TEST>Fuel pump failure forced", true)
end

local function triggerValveFailureForTesting()
    valveFailed = true
    valveFailureActive = true
    valveFailureElapsed = 0
    valveFailureMinDamage = acCarPhysics.engineLifeLeft
    valveFailureDamage = valveFailureMinDamage
    overheadMessageQueue("TEST", "Valve failure forced", 3, true)
    logDebug("<TEST>Valve failure forced", true)
end

local function triggerOilPressureFailureForTesting()
    if isManualOilPumpDriverEnabled and isManualOilPumpDriverEnabled() then
        oilPressureFailed = false
        oilPressureFailureActive = false
        oilPressureDamageActive = false
        overheadMessageQueue("TEST", "Oil pressure skipped: manual oil pump enabled", 3, true)
        logDebug("<TEST>Oil pressure failure skipped, manual oil pump enabled", true)
        return
    end

    oilPressureFailed = true
    oilPressureFailureActive = true
    oilPressureDamageActive = true
    oilPressureFailureElapsed = 0
    oilPressureFailureMinDamage = acCarPhysics.engineLifeLeft
    oilPressureFailureDamage = oilPressureFailureMinDamage
    if forceOilPressureSystemFailureForTesting then
        forceOilPressureSystemFailureForTesting()
    elseif damageOilPressurePump then
        damageOilPressurePump()
    end
    overheadMessageQueue("TEST", "Oil pressure failure forced", 3, true)
    logDebug("<TEST>Oil pressure failure forced", true)
end

local function triggerGearFailureForTesting()
    local gearIndex = getTestGearIndex()
    if markGearAsFailed then
        markGearAsFailed(gearIndex)
    else
        deadGears[gearIndex] = true
    end
    overheadMessageQueue("TEST", "Gear " .. gearIndex .. " failure forced", 3, true)
    logDebug("<TEST>Gear failure forced, gear: ", gearIndex, true)
end

local function triggerTyrePunctureForTesting(tyreIndex)
    generateSlowPuncture(tyreIndex, minPunctureDeflateFactor, maxPunctureDeflateFactor)
    tyrePunctureTestIndex = -1
    overheadMessageQueue("TEST", getWheelName(tyreIndex) .. " puncture forced", 3, true)
end

local function triggerCollisionDamageForTesting(engineLifeLoss, label)
    if highSpeedCollisionDone then
        return
    end

    ac.setEngineLifeLeft(math.max(0, acCarPhysics.engineLifeLeft - engineLifeLoss))
    if damageOilPressurePump then
        damageOilPressurePump()
    end
    if engineLifeLoss >= 750 then
        for i = 0, 1 do
            ac.setTyreInflation(i, 0)
        end
    end
    highSpeedCollisionDone = true
    overheadMessageQueue("TEST", label .. " forced", 3, true)
    logDebug("<TEST>", label, " forced", true)
end

local function triggerAlternatorFailureForTesting()
    alternatorOK = false
    alternatorHealth = 0.25
    batteryCurrentCharge = math.min(batteryCurrentCharge or 100, 20)
    batteryMaxCapacity = math.min(batteryMaxCapacity or 100, 60)
    overheadMessageQueue("TEST", "Alternator/electrical failure forced", 3, true)
    logDebug("<TEST>Alternator/electrical failure forced", true)
end

function setFailureForTesting()
    if not isCarInPits and thisCar.extraS and not prevExtraSState then
        if selectedFailure == failureTypes.clearAllFailures then
            resetCar()
            highSpeedCollisionDone = false
            tyrePunctureTestIndex = -1
        elseif selectedFailure == failureTypes.sparkPlugFailure then
            triggerSparkPlugFailureForTesting()
        elseif selectedFailure == failureTypes.fuelPumpFailure then
            triggerFuelPumpFailureForTesting()
        elseif selectedFailure == failureTypes.valveFailure then
            triggerValveFailureForTesting()
        elseif selectedFailure == failureTypes.oilPressureFailure then
            triggerOilPressureFailureForTesting()
        elseif selectedFailure == failureTypes.gearFailure then
            triggerGearFailureForTesting()
        elseif selectedFailure == failureTypes.tyrePuncture_FL then
            triggerTyrePunctureForTesting(0)
        elseif selectedFailure == failureTypes.tyrePuncture_FR then
            triggerTyrePunctureForTesting(1)
        elseif selectedFailure == failureTypes.tyrePuncture_RL then
            triggerTyrePunctureForTesting(2)
        elseif selectedFailure == failureTypes.tyrePuncture_RR then
            triggerTyrePunctureForTesting(3)
        elseif selectedFailure == failureTypes.highSpeedLightCollision1 then
            triggerCollisionDamageForTesting(500, "Collision test 150")
        elseif selectedFailure == failureTypes.highSpeedLightCollision2 then
            triggerCollisionDamageForTesting(750, "Collision test 750")
        elseif selectedFailure == failureTypes.alternatorFailure then
            triggerAlternatorFailureForTesting()
        end
    end

    prevExtraSState = thisCar.extraS
end

----------------- End of debug/testing code -----------------
