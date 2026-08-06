-- Engine thermal simulation: coolant temperature, engine temperature, radiator/air cooling setup.
-- Also handles engine damage limiting at light side collisions.

require "script_car_parameters"

-- Legacy names used by older modules. Keep these out of the car parameter
-- tuning block so they are not mistaken for values to adjust per car.
engineOverboilTemp = engineOverheatSeizureTemperatureCelsius
engineMaximumSafeTemperatureCelsius = engineOverheatSeizureTemperatureCelsius
engineHeatGainMult = engineHeatGainMultiplier
engineCoolantTransferGain = engineCoolantHeatTransferPerSecond
engineBaseCoolCoefficient = engineBlockToAmbientCoolingPerSecond
engineSpeedCoolCoefficient = engineBlockSpeedCoolingPerSecond
radiatorCoolCoefficientInitialValue = radiatorStillAirCoolingPerSecond
radiatorSpeedCoolCoefficient = radiatorAirflowCoolingPerSecond
radiatorDamageCoefficientLoss = radiatorDamageCoolingLoss
coolingSystemType = coolingSystemType or COOLING_SYSTEM_RADIATOR
airCoolingStillCoolingPerSecond = airCoolingStillCoolingPerSecond or engineBlockToAmbientCoolingPerSecond
airCoolingFanCoolingPerSecond = airCoolingFanCoolingPerSecond or 0.006
airCoolingRamAirCoolingPerSecond = airCoolingRamAirCoolingPerSecond or engineBlockSpeedCoolingPerSecond
airCoolingFanReferenceRpm = airCoolingFanReferenceRpm or math.max(engineIdleRpm * 4, 1)
airCoolingFanMinimumFactor = airCoolingFanMinimumFactor or 0.15
airCoolingFanMaximumFactor = airCoolingFanMaximumFactor or 1.15
airCoolingDamageCoolingLoss = airCoolingDamageCoolingLoss or radiatorDamageCoolingLoss * 0.5
airCoolingDisplayTemperatureLagPerSecond = airCoolingDisplayTemperatureLagPerSecond or 1.0

-- Shared state (globals accessible to script.lua for reset, logging, etc.)
local function getCurrentAmbientTemperature()
    local ambientTemperature = acCarPhysics and acCarPhysics.ambientTemperature or ac.getSim().ambientTemperature
    if ambientTemperature == nil then
        return 20
    end

    return ambientTemperature
end

local function getColdStartTemperature()
    return getCurrentAmbientTemperature() + engineColdStartTemperatureOffsetCelsius
end

coolantTemp = getColdStartTemperature() -- Store our own water temp, since the AC one is arbitrary and read-only.
engineTemp = getColdStartTemperature()  -- Engine core temp - once this hits the meltdown value its OVER.
radiatorCoolCoefficient = radiatorCoolCoefficientInitialValue
radiatorCoolCoefficientBase = radiatorCoolCoefficientInitialValue
hasRadiatorDamage = false
hasRadiatorMajorDamage = false
brakesFailed = false
totalMeltdown = false
waterTempWarning = false
engineOverheatDamageWarning = false
engineTemperaturePowerFactor = 1.0
engineTemperaturePowerAdjustedGas = 0.0
engineTemperaturePowerTemperature = engineTemp
engineTemperaturePowerReason = "normal"
thermalLowRpmCoolingMultiplier = 1.0

-- State for limitEngineDamageAtCrash. prevDamage*Engine are global so that
-- the test code in script_debug.lua can manipulate them to simulate crashes.
local bodyDamageLimitAtCrashEngine = 20
prevDamageFrontEngine = 0
prevDamageRearEngine = 0
prevDamageLeftEngine = 0
prevDamageRightEngine = 0
local currentEngineLifeLeft = acCarPhysics.engineLifeLeft
local thermalFixedStepSeconds = 1 / 120
local thermalAccumulatorMaxSeconds = 0.25
local thermalStepAccumulator = 0

-- carDamageClamp is assigned inside coolantBehavior without `local`, making it
-- a global, consistent with the original code (read by the DEBUG block in update()).

local function getCoolingSetupOpeningFactor()
    return math.clamp(radiatorCoolCoefficient / math.max(radiatorCoolCoefficientInitialValue, 0.0001), 0, 1)
end

local function interpolateCoolingMultiplier(engineRpm, startRpm, startMultiplier, endRpm, endMultiplier)
    local range = math.max(endRpm - startRpm, 1)
    local t = math.clamp((engineRpm - startRpm) / range, 0, 1)
    return startMultiplier + (endMultiplier - startMultiplier) * t
end

local function getLowRpmCoolingMultiplier(engineRpm)
    local stoppedThreshold = engineStoppedCoolingRpmThreshold or 100
    local stoppedMultiplier = engineStoppedStillCoolingMultiplier or 0.25
    local idleRpm = math.max(engineIdleRpm or 900, stoppedThreshold + 1)
    local idleMultiplier = engineIdleStillCoolingMultiplier or 0.5
    local fullRpm = math.max(engineLowRpmCoolingFullRpm or idleRpm * 2, idleRpm + 1)

    if engineRpm <= stoppedThreshold then
        return stoppedMultiplier
    end
    if engineRpm <= idleRpm then
        return interpolateCoolingMultiplier(engineRpm, stoppedThreshold, stoppedMultiplier, idleRpm, idleMultiplier)
    end
    if engineRpm < fullRpm then
        return interpolateCoolingMultiplier(engineRpm, idleRpm, idleMultiplier, fullRpm, 1.0)
    end
    return 1.0
end

local function getEngineTemperaturePowerFactor(temperature)
    local curve = engineTemperaturePowerCurve
    if not curve or #curve == 0 then
        return 1.0
    end

    if temperature <= curve[1].temp then
        return curve[1].factor
    end

    for i = 2, #curve do
        local previousPoint = curve[i - 1]
        local currentPoint = curve[i]
        if temperature <= currentPoint.temp then
            local range = math.max(currentPoint.temp - previousPoint.temp, 0.001)
            local t = math.clamp((temperature - previousPoint.temp) / range, 0, 1)
            return previousPoint.factor + (currentPoint.factor - previousPoint.factor) * t
        end
    end

    return curve[#curve].factor
end

function applyEngineTemperaturePower(dt)
    if engineTemperaturePowerEnabled == false then
        engineTemperaturePowerFactor = 1.0
        engineTemperaturePowerAdjustedGas = acCarPhysics.gas or 0
        engineTemperaturePowerTemperature = engineTemp
        engineTemperaturePowerReason = "disabled"
        return
    end

    local temperature = engineTemp or 20
    local factor = math.clamp(getEngineTemperaturePowerFactor(temperature), 0.05, 1.0)
    local originalGas = math.clamp(acCarPhysics.gas or 0, 0, 1)
    local adjustedGas = originalGas * factor

    acCarPhysics.gas = adjustedGas
    engineTemperaturePowerFactor = factor
    engineTemperaturePowerAdjustedGas = adjustedGas
    engineTemperaturePowerTemperature = temperature

    if factor < 0.985 then
        engineTemperaturePowerReason =
            temperature < 70 and "cold" or "hot"
    else
        engineTemperaturePowerReason = "normal"
    end

    printDebug("Engine temp power", string.format(
        "Temp: %.1f C | Mult: %.3f | Gas: %.3f -> %.3f | %s",
        temperature,
        factor,
        originalGas,
        adjustedGas,
        engineTemperaturePowerReason))

end

local function resetEngineTemperaturePowerState()
    engineTemperaturePowerFactor = 1.0
    engineTemperaturePowerAdjustedGas = 0.0
    engineTemperaturePowerTemperature = engineTemp
    engineTemperaturePowerReason = "normal"
end

local function updateAirCooledThermalStep(stepDt, ambientTemperature, engineTemperatureAboveAmbient, carSpeedSquared, engineRpm, stoppedCoolingMultiplier)
    local coolingSetupOpeningFactor = getCoolingSetupOpeningFactor()
    local fanSpeedFactor = math.clamp(
        engineRpm / math.max(airCoolingFanReferenceRpm, 1),
        airCoolingFanMinimumFactor,
        airCoolingFanMaximumFactor)
    local fanEfficiency = getAirCoolingFanEfficiency and getAirCoolingFanEfficiency() or 1
    local coolingDamageEfficiencyFactor = math.clamp(1 - airCoolingDamageCoolingLoss * carDamageClamp, 0.25, 1)
    local fanCooling = airCoolingFanCoolingPerSecond * fanSpeedFactor * fanEfficiency * stoppedCoolingMultiplier
    if airCoolingHasMechanicalFan and not airCoolingHasMechanicalFan() then
        fanCooling = 0
    end
    local airCoolingFactor =
        (airCoolingStillCoolingPerSecond * stoppedCoolingMultiplier +
        fanCooling +
        airCoolingRamAirCoolingPerSecond * carSpeedSquared) *
        engineTemperatureAboveAmbient *
        coolingSetupOpeningFactor *
        coolingDamageEfficiencyFactor

    engineTemp = engineTemp - airCoolingFactor * stepDt

    -- Keep CPHYS_SCRIPT_0 useful for existing gauges/controllers. On an
    -- air-cooled car it represents a lagged cylinder-head/engine temperature,
    -- not water temperature.
    coolantTemp = coolantTemp + (engineTemp - coolantTemp) * math.clamp(airCoolingDisplayTemperatureLagPerSecond * stepDt, 0, 1)
    coolantTemp = math.max(coolantTemp, ambientTemperature)
end

local function updateRadiatorCooledThermalStep(stepDt, ambientTemperature, coolantTemperatureAboveAmbient, carSpeedSquared, stoppedCoolingMultiplier)
    -- Radiator damage reduces both still-air and ram-air cooling. Shutter setup
    -- also scales both, so closed shutters make warm-up quicker and racing
    -- temperatures higher.
    local shutterOpeningFactor = getCoolingSetupOpeningFactor()
    local radiatorDamageEfficiencyFactor = math.clamp(1 - radiatorDamageCoolingLoss * carDamageClamp, 0.05, 1)
    local radiatorCoolingFactor =
        (radiatorStillAirCoolingPerSecond * stoppedCoolingMultiplier + radiatorAirflowCoolingPerSecond * carSpeedSquared) *
        coolantTemperatureAboveAmbient *
        shutterOpeningFactor *
        radiatorDamageEfficiencyFactor
    coolantTemp = coolantTemp - (radiatorCoolingFactor * stepDt)

    -- Exchange heat between engine metal and coolant in both directions.
    local engineCoolantTemperatureDifference = engineTemp - coolantTemp
    local heatTransferAmount = engineCoolantTemperatureDifference * engineCoolantHeatTransferPerSecond * stepDt

    -- This lets cold coolant absorb heat after starting, and hot coolant keep
    -- some warmth in the engine after the driver lifts.
    engineTemp = engineTemp - heatTransferAmount * (1 - engineCoolantTransferBalance)
    coolantTemp = coolantTemp + heatTransferAmount * engineCoolantTransferBalance
end

local function applyThermalStep(stepDt, ambientTemperature)
    -- All cooling/engine thermals are handled here. Temperatures are allowed
    -- to begin near ambient and can be below zero in winter conditions. Cooling
    -- only depends on positive temperature difference above ambient, avoiding the
    -- old log(temp - ambient) behaviour that could break around freezing starts.
    local engineTemperatureAboveAmbient = math.max(engineTemp - ambientTemperature, 0)
    local coolantTemperatureAboveAmbient = math.max(coolantTemp - ambientTemperature, 0)
    local engineRpm = math.max(acCarPhysics.rpm or thisCar.rpm or 0, 0)
    local lowRpmCoolingMultiplier = getLowRpmCoolingMultiplier(engineRpm)
    thermalLowRpmCoolingMultiplier = lowRpmCoolingMultiplier
    local engineRpmFactor = math.clamp(engineRpm / math.max(engineIdleRpm * 3.8, 1), 0, 1.25)
    local engineRunningFactor = math.clamp((engineRpm - 80) / math.max(engineIdleRpm - 80, 1), 0, 1)
    local throttleLoadFactor = math.clamp(acCarPhysics.gas or 0, 0, 1)

    -- Idle heat warms the engine quickly after starting; load heat then takes
    -- over as RPM and throttle rise during racing.
    local engineHeatingFactor =
        (engineIdleHeatGainCelsiusPerSecond * engineRunningFactor +
        engineFullLoadHeatGainCelsiusPerSecond * engineRpmFactor * throttleLoadFactor) *
        currentEngineHeatGainMult *
        (engineHeatGainEngineMapFactors[(thisCar.fuelMap or 0) + 1] or 1)

    if oilPressureFailureActive == true then
        engineHeatingFactor = engineHeatingFactor * 1.25
    end

    local carSpeedKmh = acCarPhysics.speedKmh or thisCar.speedKmh or 0
    local carSpeedSquared = carSpeedKmh * carSpeedKmh
    local engineBlockSpeedCooling = 0
    if not (isAirCoolingSystemEnabled and isAirCoolingSystemEnabled()) then
        engineBlockSpeedCooling = engineBlockSpeedCoolingPerSecond * carSpeedSquared
    end
    local engineCoolingFactor =
        (engineBlockToAmbientCoolingPerSecond * lowRpmCoolingMultiplier + engineBlockSpeedCooling) *
        engineTemperatureAboveAmbient
    engineTemp = engineTemp + ((engineHeatingFactor - engineCoolingFactor) * stepDt)

    if isAirCoolingSystemEnabled and isAirCoolingSystemEnabled() then
        updateAirCooledThermalStep(stepDt, ambientTemperature, engineTemperatureAboveAmbient, carSpeedSquared, engineRpm, lowRpmCoolingMultiplier)
    else
        updateRadiatorCooledThermalStep(stepDt, ambientTemperature, coolantTemperatureAboveAmbient, carSpeedSquared, lowRpmCoolingMultiplier)
    end

    -- Do not force a warm minimum. The only lower bound is ambient air, so the
    -- car can start below zero without numerical issues and then warm naturally.
    coolantTemp = math.max(coolantTemp, ambientTemperature)
    engineTemp = math.max(engineTemp, ambientTemperature)
end

function getBrakeDuctWingGain(brakeDuctPercentage)
    local steps = {
        {duct = 0, wingGain = 1.00000},
        {duct = 30, wingGain = 0.99200},
        {duct = 60, wingGain = 0.98400},
        {duct = 90, wingGain = 0.97600},
    }

    -- Find the step with the brakeDuctPercentage value. Default to the first step if not found.
    local s = steps[1]
    for _, step in ipairs(steps) do
        if step.duct == brakeDuctPercentage then
            s = step
            break
        end
    end

    return s.wingGain
end

--radiator setup
function applyRadiatorSetup(setup)
    setup = math.clamp(tonumber(setup) or 0, 0, 4)
    local flapPosition

    if isAirCoolingSystemEnabled and isAirCoolingSystemEnabled() then
        flapPosition = {
            "Cooling intake fully open",
            "Cooling intake one quarter closed",
            "Cooling intake half closed",
            "Cooling intake three quarters closed",
            "Cooling intake almost closed"
        }
    else
        flapPosition = {
            "Shutters fully open",
            "Shutters one quarter closed",
            "Shutters half closed",
            "Shutters three quarters closed",
            "Shutters almost closed"
        }
    end

    -- Get brake duct settings from setup and combine their effects with the radiator setup.
    local brakeDuctPercentageFront = ac.getScriptSetupValue("BRAKE_DUCT_F")()
    printDebug("BrakeDuct F", brakeDuctPercentageFront)
    local brakeDuctPercentageRear = ac.getScriptSetupValue("BRAKE_DUCT_R")()
    printDebug("BrakeDuct R", brakeDuctPercentageRear)
    local brakeDuctWingGainFront = getBrakeDuctWingGain(brakeDuctPercentageFront)
    printDebug("BrakeDuct Wing Gain F", brakeDuctWingGainFront)
    local brakeDuctWingGainRear = getBrakeDuctWingGain(brakeDuctPercentageRear)
    printDebug("BrakeDuct Wing Gain R", brakeDuctWingGainRear)

    -- map setup steps to wing gain + cooling multiplier
    local steps = {
        {wingIndex = 0, wingGain = 1.00000, coolMul = 1.00},
        {wingIndex = 0, wingGain = 0.98000, coolMul = 0.85},
        {wingIndex = 0, wingGain = 0.96000, coolMul = 0.70},
        {wingIndex = 0, wingGain = 0.94000, coolMul = 0.55},
        {wingIndex = 0, wingGain = 0.92000, coolMul = 0.40},
    }
    local s = steps[setup + 1]
    ac.setWingGain(s.wingIndex, s.wingGain * brakeDuctWingGainFront * brakeDuctWingGainRear, 1)
    printDebug("Combined Wing Gain", s.wingGain * brakeDuctWingGainFront * brakeDuctWingGainRear)
    radiatorCoolCoefficientBase = radiatorCoolCoefficientInitialValue * s.coolMul
    return flapPosition[setup + 1]
end

local function getCoolingBodyDamage()
    local damage = thisCar.damage
    -- Preserve the previous front-and-side radiator behaviour for cars which
    -- have not yet added coolingDamageSides to their parameters.
    local sides = coolingDamageSides or {true, false, true, true}
    local totalDamage = 0
    local selectedSideCount = 0

    if sides[1] then
        totalDamage = totalDamage + (damage[0] or 0)
        selectedSideCount = selectedSideCount + 1
    end
    if sides[2] then
        totalDamage = totalDamage + (damage[1] or 0)
        selectedSideCount = selectedSideCount + 1
    end
    if sides[3] then
        totalDamage = totalDamage + (damage[2] or 0)
        selectedSideCount = selectedSideCount + 1
    end
    if sides[4] then
        totalDamage = totalDamage + (damage[3] or 0)
        selectedSideCount = selectedSideCount + 1
    end

    return selectedSideCount > 0 and totalDamage / selectedSideCount or 0
end

--coolant behavior/engine damage handling
function coolantBehavior(dt)
    local ambientTemperature = getCurrentAmbientTemperature()
    local coolingBodyDamage = getCoolingBodyDamage()
    carDamageClamp = math.clampN(coolingBodyDamage * 0.01, 0, 1)
    --clamp the actual bumper damage as ac can make it over 100%
    if coolingBodyDamage > 30 then
        if hasRadiatorDamage == false then
            hasRadiatorDamage = true
            overheadMessageQueue("Cooling damage", "Engine cooling is slightly damaged. Watch for engine temps.", 2)
        end
    end

    --if damage is over 50% you lose some of the brake power
    if thisCar.damage[0] > 50 or thisCar.damage[2] > 50 or thisCar.damage[3] > 50 then
        if brakesFailed == false then
            brakesFailed = true
            overheadMessageQueue("Brake problem", "Front damage caused brakes to lose power. Take it careful!", 3)
        end
    end
    if brakesFailed == true then
        if randomBrakeLimit == nil then
            randomBrakeLimit = 0.4 + math.random() * (0.9 - 0.4)
        end
        if acCarPhysics.brake > randomBrakeLimit then
            acCarPhysics.brake = randomBrakeLimit
        end
    end


    if coolingBodyDamage > 75 then
        if hasRadiatorMajorDamage == false then
            hasRadiatorMajorDamage = true
            if acCarPhysics.engineLifeLeft > 500 then
                acCarPhysics.engineLifeLeft = 500
            end
            overheadMessageQueue("Major cooling damage", "Engine cooling has major damage. Watch for engine temps.", 2)
        end
    end

    if engineTemp > engineOverheatDamageStartTemperatureCelsius and not engineOverheatDamageWarning then
        overheadMessageQueue("Engine overheating", "Engine temperature is causing damage. Ease off and cool it down.", 4)
        engineOverheatDamageWarning = true
    end

    local warningTemperature = (isAirCoolingSystemEnabled and isAirCoolingSystemEnabled()) and engineTemp or coolantTemp
    if warningTemperature > engineOverheatWarningTemperatureCelsius and not waterTempWarning then
        local warningTitle = (isAirCoolingSystemEnabled and isAirCoolingSystemEnabled()) and "Engine temperature" or "Coolant temperature"
        local warningText = (isAirCoolingSystemEnabled and isAirCoolingSystemEnabled())
            and "Engine temperature is getting high. Ease off and keep air moving."
            or "Water temperature is nearing boiling point. Hold off the throttle."
        overheadMessageQueue(warningTitle, warningText, 3)
        waterTempWarning = true
    end

    if engineTemp < engineOverheatDamageStartTemperatureCelsius - 4 then
        engineOverheatDamageWarning = false
    end

    if warningTemperature < engineOverheatWarningTemperatureCelsius - 4 then
        waterTempWarning = false
    end

    if engineTemp > engineOverheatDamageStartTemperatureCelsius and not totalMeltdown then
        local overheatRangeCelsius = math.max(engineOverheatSeizureTemperatureCelsius - engineOverheatDamageStartTemperatureCelsius, 1)
        local overheatSeverity = math.clamp((engineTemp - engineOverheatDamageStartTemperatureCelsius) / overheatRangeCelsius, 0, 1)
        local rpmDamageMultiplier = math.clamp((acCarPhysics.rpm or thisCar.rpm or 0) / math.max(engineIdleRpm * 3.5, 1), 0.25, 1.5)
        local overheatDamagePerSecond =
            engineOverheatBaseDamagePerSecond +
            engineOverheatSevereDamagePerSecond * overheatSeverity * overheatSeverity
        local engineLifeAfterOverheatDamage =
            math.max(acCarPhysics.engineLifeLeft - overheatDamagePerSecond * rpmDamageMultiplier * dt, 0)
        ac.setEngineLifeLeft(engineLifeAfterOverheatDamage)

        if engineTemp > engineOverheatSeizureTemperatureCelsius or engineLifeAfterOverheatDamage <= 0 then
            totalMeltdown = true
            overheadMessageQueue("Engine seized", "The overheated engine has failed.", 5)
            ac.setEngineLifeLeft(0)
        end
    end

    thermalStepAccumulator = math.min(thermalStepAccumulator + dt, thermalAccumulatorMaxSeconds)
    while thermalStepAccumulator >= thermalFixedStepSeconds do
        applyThermalStep(thermalFixedStepSeconds, ambientTemperature)
        thermalStepAccumulator = thermalStepAccumulator - thermalFixedStepSeconds
    end

    acCarPhysics.controllerInputs[0] = coolantTemp
    acCarPhysics.controllerInputs[1] = engineTemp
    --these dynamic controllers can be read by analog or digital instruments with INPUT = CPHYS_SCRIPT_X

end--end of coolant behavior function

function resetThermalTemperaturesToAmbient()
    coolantTemp = getColdStartTemperature()
    engineTemp = getColdStartTemperature()
    thermalStepAccumulator = 0
    carDamageClamp = 0
    prevDamageFrontEngine = thisCar.damage[0] or 0
    prevDamageRearEngine = thisCar.damage[1] or 0
    prevDamageLeftEngine = thisCar.damage[2] or 0
    prevDamageRightEngine = thisCar.damage[3] or 0
    currentEngineLifeLeft = 1000
    hasRadiatorDamage = false
    brakesFailed = false
    randomBrakeLimit = nil
    totalMeltdown = false
    waterTempWarning = false
    engineOverheatDamageWarning = false
    resetEngineTemperaturePowerState()
end

function limitEngineDamageAtCrash()
    -- When the car touches for example a wall just slightly, the engine can take a huge amount of damage,
    -- which is not very realistic. To limit this, we can check the change in damage at front, and if it's
    -- not too big, then we can limit the engine damage.
    local damageDiffFront = thisCar.damage[0] - prevDamageFrontEngine
    local damageDiffRear = thisCar.damage[1] - prevDamageRearEngine
    local damageDiffLeft = thisCar.damage[2] - prevDamageLeftEngine
    local damageDiffRight = thisCar.damage[3] - prevDamageRightEngine
    printDebug("DmgFront", thisCar.damage[0])
    printDebug("DmgRear", thisCar.damage[1])
    printDebug("DmgLeft", thisCar.damage[2])
    printDebug("DmgRight", thisCar.damage[3])

    -- Do not protect genuine hard front/rear crashes. Those are allowed to
    -- destroy the engine outright, which also lets crash-fire visuals trigger.
    if damageDiffFront >= bodyDamageLimitAtCrashEngine or damageDiffRear >= bodyDamageLimitAtCrashEngine then
        printDebug("Engine crash limiter", "Skipped: hard front/rear impact")
    elseif damageDiffLeft > 0 or damageDiffRight > 0 then
        local engineLifeLossFromAC = math.max(currentEngineLifeLeft - acCarPhysics.engineLifeLeft, 0)
        local allowedEngineDamage = math.max(damageDiffFront + damageDiffRear, 0) * 10
        local maxEngineDamage = math.min(engineLifeLossFromAC, allowedEngineDamage)
        printDebug("damageDiffFront", damageDiffFront)
        printDebug("damageDiffRear", damageDiffRear)
        printDebug("Engine life left before", currentEngineLifeLeft)
        ac.setEngineLifeLeft(currentEngineLifeLeft - maxEngineDamage)
        printDebug("Engine life left after", acCarPhysics.engineLifeLeft)
    end

    --[[ Legacy equivalent kept as comment for context:
    if damageDiffLeft > 0 or damageDiffRight > 0 then
        if damageDiffFront < bodyDamageLimitAtCrashEngine and damageDiffRear < bodyDamageLimitAtCrashEngine then
            local maxEngineDamage = math.min(currentEngineLifeLeft - acCarPhysics.engineLifeLeft, (damageDiffFront + damageDiffRear) * 10)
            printDebug("damageDiffFront", damageDiffFront)
            printDebug("damageDiffRear", damageDiffRear)
            printDebug("Engine life left before", currentEngineLifeLeft)
            ac.setEngineLifeLeft(currentEngineLifeLeft - maxEngineDamage)
            printDebug("Engine life left after", acCarPhysics.engineLifeLeft)
        end
    end
    ]]

    printDebug("Engine life", acCarPhysics.engineLifeLeft)
    prevDamageFrontEngine = thisCar.damage[0]
    prevDamageRearEngine = thisCar.damage[1]
    prevDamageLeftEngine = thisCar.damage[2]
    prevDamageRightEngine = thisCar.damage[3]
    currentEngineLifeLeft = acCarPhysics.engineLifeLeft
end
