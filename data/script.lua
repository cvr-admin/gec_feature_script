--Historic damage script by SLIGHTLYMADESTUDIOS
--youregoingtobrazil.eu - tunarisgame.com
--description:
--big ups to Garamond247 for commissioning!
--add gobs of simulation value to your historics, including:

--random fuel pump damage
--random oil pressure problems
--random valve damage
--basic radiator damage
--basic coolant temp sim
--random spark plug failure
--random gear loss
--brake wear
--starter/stall system
--random tyre durability
--on-road tyre service
--spares, configurable carry-on spares wheels
--a basic message queue system to inform driver of instrument statuses
--slow tyre puncture

--[[ Failure Probability (2h Race and 24h race)
6666.7 ~41.74%
10000 ~30.12%
15000 ~21.34%
20000 ~16.52%
30000 ~11.29%
50000 ~6.94%
60000 ~5.8%
70000 ~5.0%
80000 ~4.4%
90000 ~3.9%
100000 ~3.5%
150000 ~2.37% - 25.1%
200000 ~1.79%
300000 ~1.19%
400000 ~0.90%
500000 ~0.72% - 8.5%
750000 ~0.48%
1000000 ~0.36% - 4.2%

10,000 + 39,000 = 36.39%
50,000 + 42,000 = 14.61%
]]

local VERSION = "3.3"

acCarPhysics = ac.accessCarPhysics() --extension physics shortcut

--READ ONLY

thisCar = car or ac.getCar()

require "script_car_parameters"

local isAICar = acCarPhysics.inputMethod == ac.InputMethod.AI

if isAICar then
    -- AI gets a lightweight reliability layer only. The full human damage script
    -- is too input-heavy and repair-menu dependent for computer-controlled cars.
    require "script_ai_failures"
    initAIFailureSystem(acCarPhysics, thisCar)
end

local new_throttle_model = nil
local rescue = nil

if not isAICar then
    require "script_supercharger"
    require "script_failure_rate_handling"
    require "script_electricity"
    require "script_psg"

    new_throttle_model = require("script_throttle")
    rescue = require("script_rescue_push")
    rescue.init(acCarPhysics)
end

-- Enable/disable debug prints and test code.
-- *** Must always be false in release packages! ***
local DEBUG = false
local DEBUG_LOG_FILE = true  -- Left logging enabled for release 2.0.
local TEST_CODE = false
-- Extra T: cycles/selects the test failure type. Extra S: triggers the currently selected failure.

if setElectricityDebugEnabled then
    setElectricityDebugEnabled(DEBUG)
end

-- Override can be used to temporarily ignore the DEBUG flag,
-- if you want to print only certain debug data, but not all.
function printDebug(str1, str2, override)
    override = override or false
    if DEBUG or override then
        ac.debug(str1, str2)
    end
end

-- Log debug messages to the csp log file. Append 'true' as the last argument
-- to force logging regardless of the DEBUG_LOG_FILE flag.
-- For example: logDebug("This will always be logged!", true)
--              logDebug("This will be logged only if DEBUG_LOG_FILE is true.")
function logDebug(...)
    local argCount = select('#', ...)
    local lastArg = select(argCount, ...)
    local isLastArgBooleanAndTrue = argCount > 0 and type(lastArg) == "boolean" and lastArg == true

    if DEBUG_LOG_FILE or isLastArgBooleanAndTrue then
        local args = {...}
        local message = "CVR_LOG " .. os.date("[%H:%M:%S]") .. "\t"
        local limit = isLastArgBooleanAndTrue and (#args - 1) or #args
        for i = 1, limit do
            message = message .. tostring(args[i])
        end
        ac.log(message)
    end
end

-- New subsystem modules. Order matters: overhead_messages first so overheadMessageQueue
-- is available to all modules that follow. All placed after printDebug/logDebug so
-- module-load-time code can call them safely.
if not isAICar then
    require "script_overhead_messages"
    require "script_engine_failures"
    require "script_gearbox"
    require "script_dogbox"
    require "script_tyre"
    require "script_thermal"
    require "script_air_cooling"
    require "script_engine_starter"
    require "script_fuel"
    require "script_oil"
    require "script_brakes"
    -- script_debug is required later (after failure rate vars are initialised below).
end

local doOnceAtStart = false

if not isAICar then
    initTurboVariables(ac, printDebug, logDebug)
    initFailureHandlingVariables(printDebug, logDebug)
end

local superchargerExists = 0
if not isAICar and getTurboCount() > 0 then
    superchargerExists = 1
end

local turboFailureTimer = 0
currentEngineHeatGainMult = engineHeatGainMult
local prevFailedTurboCount = 0
local turboSmokeDuration = 25
local turboSmokeTimer = turboSmokeDuration

-- Teleport to pits callback. Will be called when the car is teleported to pits.
-- When this happens we will prevent starting of the engine, thus ending the race
-- for the car that was teleported to pits.
carHasTeleportedToPits = false
local lastCarWorldPosition = nil

local function updateLastCarWorldPosition()
    local position = thisCar.position
    if position then
        lastCarWorldPosition = vec3(position.x, position.y, position.z)
    end
end

function teleportToPitsCallback(carIndex)
    printDebug("Car teleported to pits", "Car index: " .. carIndex)
    printDebug("This car index", "Car index: " .. thisCar.index)
    local raceStarted = (ac.getSim().raceSessionType == ac.SessionType.Race and ac.getSim().isSessionStarted)

    if raceStarted and thisCar.isInPit then
        carHasTeleportedToPits = true
    end

    if carIndex == thisCar.index and thisCar.isInPit then
        local keepRaceTeleportLockout = carHasTeleportedToPits
        local jumpDistance = lastCarWorldPosition and thisCar.position
            and vec3.distance(lastCarWorldPosition, thisCar.position) or 0
        -- CSP also uses this callback for an in-place pit state refresh. A real
        -- return-to-pits jump moves the car to its box and must reset everything.
        resetCar(jumpDistance > 5)
        updateLastCarWorldPosition()
        carHasTeleportedToPits = keepRaceTeleportLockout
    end
end

ac.onCarJumped(thisCar.index, teleportToPitsCallback)

local optimizationTimer = 0 --run a small timer rather than running some of the checks every tick. should save on CPU.

local radiatorSetup = nil   -- handled by setupBits now
local prevRadiatorSetup = 0
local turboEnabled = true
local prevextraDState = false
local prevextraEState = false
local prevextraFState = false
local pitWaterCoolingApplied = false

local hasEngineDamage = false
local prevEngineLifeForCrashFire = 1000
local prevCrashFireDamageFront = 0
local prevCrashFireDamageRear = 0
local prevCrashFireDamageLeft = 0
local prevCrashFireDamageRight = 0
local engineCrashFireTimer = 0
local engineCrashFireIntensity = 0

local ENGINE_MAP_RICH = 0
local ENGINE_MAP_NORMAL = 1
local ENGINE_MAP_LEAN = 2
local ENGINE_MAP_PUSH = 3
local EGINE_MAP_DESCRIPTIONS = { "Rich", "Normal", "Lean", "Push" }

-- Failure rates. Base rates are global so that failure_rate_handling and script_debug can access them.
-- The actual (engine-map-adjusted) rates are also global so that the failure functions can read them.
sparkPlugFailureRate = sparkPlugFailureRateInitialValue
sparkPlugFailureRateBase = sparkPlugFailureRateInitialValue
fuelPumpFailureRate = fuelPumpFailureRateInitialValue
fuelPumpFailureRateBase = fuelPumpFailureRateInitialValue
valveFailureRate = valveFailureRateInitialValue
valveFailureRateBase = valveFailureRateInitialValue
oilPressureFailureRate = oilPressureFailureRateInitialValue
oilPressureFailureRateBase = oilPressureFailureRateInitialValue
remFlags = remFlags or {}

local prevEngineMap = -1
local prevLapCount = 0

local failureRateHandlingTimer = 0
local failureRateHandlingInterval = 0.3

trackSurfaceType = ac.SurfaceExtendedType.Base

local mediumSpeedDtTimer = 0
local tyreBlowCrashingTimer = 0

local function resetEngineCrashFire()
    prevEngineLifeForCrashFire = acCarPhysics.engineLifeLeft or 1000
    prevCrashFireDamageFront = thisCar.damage[0] or 0
    prevCrashFireDamageRear = thisCar.damage[1] or 0
    prevCrashFireDamageLeft = thisCar.damage[2] or 0
    prevCrashFireDamageRight = thisCar.damage[3] or 0
    engineCrashFireTimer = 0
    engineCrashFireIntensity = 0
end

local function updateEngineCrashFire(dt)
    if not engineCrashFireEnabled then
        acCarPhysics.controllerInputs[80] = 0
        acCarPhysics.controllerInputs[81] = 0
        acCarPhysics.controllerInputs[82] = 0
        return
    end

    local damageFront = thisCar.damage[0] or 0
    local damageRear = thisCar.damage[1] or 0
    local damageLeft = thisCar.damage[2] or 0
    local damageRight = thisCar.damage[3] or 0
    local directEngineDamageDelta = math.max(
        damageFront - prevCrashFireDamageFront,
        damageRear - prevCrashFireDamageRear,
        0)
    local speedKmh = math.max(acCarPhysics.speedKmh or 0, thisCar.speedKmh or 0)
    local engineLife = acCarPhysics.engineLifeLeft or 1000

    if engineCrashFireTimer <= 0
            and prevEngineLifeForCrashFire > engineCrashFireEngineLifeThreshold
            and engineLife <= engineCrashFireEngineLifeThreshold
            and directEngineDamageDelta >= engineCrashFireDamageDeltaThreshold
            and speedKmh >= engineCrashFireMinimumSpeedKmh then
        local severity = math.clamp(
            (directEngineDamageDelta - engineCrashFireDamageDeltaThreshold) /
            math.max(100 - engineCrashFireDamageDeltaThreshold, 1),
            0,
            1)
        engineCrashFireTimer = engineCrashFireDurationSeconds
        engineCrashFireIntensity = engineCrashFireIntensityMin +
            (engineCrashFireIntensityMax - engineCrashFireIntensityMin) * severity
        overheadMessageQueue("Engine fire", "Hard impact has ignited the engine bay", 5)
    end

    if engineCrashFireTimer > 0 then
        engineCrashFireTimer = math.max(0, engineCrashFireTimer - dt)
    end

    acCarPhysics.controllerInputs[80] = engineCrashFireTimer > 0 and 1 or 0
    acCarPhysics.controllerInputs[81] = engineCrashFireTimer > 0 and engineCrashFireIntensity or 0
    acCarPhysics.controllerInputs[82] = engineCrashFireTimer > 0 and
        math.clamp(engineCrashFireTimer / math.max(engineCrashFireDurationSeconds, 0.001), 0, 1) or 0

    prevEngineLifeForCrashFire = engineLife
    prevCrashFireDamageFront = damageFront
    prevCrashFireDamageRear = damageRear
    prevCrashFireDamageLeft = damageLeft
    prevCrashFireDamageRight = damageRight
end

-- call once so current setup is applied on load - this did not work because AC's logic on that matter is weird. Now handled in setupBits
--applyRadiatorSetup(radiatorSetup)

-- script_debug required here so that its module-level code runs after all vars above are set.
if not isAICar then
    require "script_debug"
end

-- Initialise failure type counter for test code (captures orig failure rate values).
-- AI cars do not load script_debug.lua, where initFailureTypeCount() is defined.
if TEST_CODE and not isAICar then
    initFailureTypeCount()
end

--this quick helper func to convert some of the setup params to bool.
local function inputToBool(value)
    return value == true or value == 1 or value == "1"
end

local function updateScriptSetupToggles()
    if isNonSynchroGearboxEnabled() and edwardianGearboxSetupToggleEnabled then
        setDoubleClutchGearboxSetupEnabled(inputToBool(ac.getScriptSetupValue("DOUBLE_CLUTCH_GEARBOX")()))
    else
        setDoubleClutchGearboxSetupEnabled(true)
    end

    if setManualOilPumpDriverEnabled then
        setManualOilPumpDriverEnabled(inputToBool(ac.getScriptSetupValue("MANUAL_OIL_PUMP")()))
    end

    if setManualFuelPressureDriverEnabled then
        setManualFuelPressureDriverEnabled(inputToBool(ac.getScriptSetupValue("MANUAL_FUEL_PRESSURE")()))
    end
end

local function getThermalStressTemperature()
    if isAirCoolingSystemEnabled and isAirCoolingSystemEnabled() then
        return engineTemp
    end

    return coolantTemp
end

local function getCoolingSetupTitle()
    if isAirCoolingSystemEnabled and isAirCoolingSystemEnabled() then
        return "Cooling intake setup"
    end

    return "Radiator setup"
end

--this function gets the setup menu values for the tyre pressures (so that when you restore a wheel, it gives the correct static pressure, in case its not built-in)
--and also the count of spare wheels. the spare wheels get also replaced with a fresh set of spares when you pit.

--get some setup params when leaving pits so that they can be reset to the original state at one point or another
local function setupBits(dt)
    local inGrid = (ac.getSim().raceSessionType == ac.SessionType.Race and not ac.getSim().isSessionStarted)
    if not isCarInPits then
        pitWaterCoolingApplied = false
    end

    applyCVRPitCrewTyreSelection(dt)

    --check if cars in pit to reset the values, and also check nil for initialization
    if isCarInPits or inGrid or tyrePressures[0] == nil then
        --get setup tyre pressures, and initialize vKMs
        if ac.getCar(0).isChangingTyres or inGrid or tyrePressures[0] == nil then
            for i = 0, 3 do
                -- 1.0 means inflated to the pressure defined in the setup.
                tyrePressures[i] = 1.0
                ac.setTyreInflation(i, tyrePressures[i])
                --ac.debug("Tyre stuff fired",i)
                -- Only generate a new lifespan if the tyre is not already initialized
                if not tyrevKMs[i] or tyrevKMs[i] < thisCar.wheels[i].tyreVirtualKM then
                    tyrevKMs[i] = generateTyrevKM()
                    -- tyrevKMs[i] = thisCar.wheels[i].tyreVirtualKM + generateTyrevKM()
                end
                --debugTyrevKMs() -- Log initialized vKM values
                tyrePunctureDeflateFactor[i] = 0.0

                -- Reset the tyre wear for the replaced tyre(s).
                resetTyreWearTracking(i)
            end--end of tyre vKM generation

            -- Check if brake wear is to be reset when changing tyres in pits.
            -- This is done outside the per-wheel loop since brakeWearLevel is a single value.
            -- We check isChangingTyres directly rather than tyreVirtualKM, because the game
            -- resets VKM only after the tyre change completes (i.e. after isChangingTyres turns false),
            -- so VKM is still the old value while this code runs.
            if resetBrakeWearAtTyreChange == true and ac.getCar(0).isChangingTyres then
                brakeWearLevel = 0.0
            end
        end

        -- Get a bunch of stuff that should be reset when you enter pits
        -- but only if engine has been fixed already.
        if acCarPhysics.engineLifeLeft == 1000 then
            valveFailed = false
            valveFailureActive = false
            valveFailureElapsed = 0
            valveFailureDamage = valveFailureMinDamage

            -- Cut the failure rate losses to half, if the engine has been fixed,
            -- i.e. if there was engine damage before entering the pits.
            if hasEngineDamage then
                sparkPlugFailureRateBase = sparkPlugFailureRateBase + (sparkPlugFailureRateInitialValue - sparkPlugFailureRateBase) * 0.5
                valveFailureRateBase = valveFailureRateBase + (valveFailureRateInitialValue - valveFailureRateBase) * 0.5
                oilPressureFailureRateBase = oilPressureFailureRateBase + (oilPressureFailureRateInitialValue - oilPressureFailureRateBase) * 0.5
                hasEngineDamage = false
            end
        end

        --[[ for i = 1, thisCar.gearCount do
        --offset the index by 1 due to janky implementation
        deadGears[i + 1] = false
        end ]]

        --get count of spare wheels equipped in the setup
        --and add the additional mass
        --MAKE SURE TO ADD THE LINE INTO THE SETUP.INI!!!
        currentSpares = getCurrentSpares()
        overheadMessagesEnabled = inputToBool(ac.getScriptSetupValue("OVERHEAD_MESSAGES")())

        tyreChangeInProgress = false

        -- Pit crew cooling: if the engine/cooling system arrives very hot,
        -- knock heat out once instead of snapping temperatures to a fixed value.
        if isCarInPits and not pitWaterCoolingApplied then
            if cleanRadiatorDustClog then
                cleanRadiatorDustClog(radiatorDustClogPitCleanFraction)
            end

            if not (isAirCoolingSystemEnabled and isAirCoolingSystemEnabled()) and coolantTemp > pitWaterCoolingTemperatureThresholdCelsius then
                coolantTemp = coolantTemp - pitWaterCoolingDropCelsius
            end

            if engineTemp > pitWaterCoolingTemperatureThresholdCelsius then
                engineTemp = engineTemp - pitWaterCoolingDropCelsius
                if isAirCoolingSystemEnabled and isAirCoolingSystemEnabled() then
                    coolantTemp = math.min(coolantTemp, engineTemp)
                end
            end

            pitWaterCoolingApplied = true
        end

        -- Once the crew has cooled the car enough, allow temperature warnings
        -- to appear again later if it overheats after leaving the pits.
        if getThermalStressTemperature() < engineOverheatWarningTemperatureCelsius - 4 then
            waterTempWarning = false
        end

        if engineTemp < engineOverheatDamageStartTemperatureCelsius - 4 then
            engineOverheatDamageWarning = false
        end
        --SETTING CAR EXTRA MASS (SPARE WHEEL) CAN BE DONE IN UPDATE LOOP!!
    end--end of checking if car is in pits insanity

    updateScriptSetupToggles()

    if ((lastSetupRad or -1) ~= ac.getScriptSetupValue("RADIATOR")()) or radiatorSetup == nil then
        radiatorSetup = ac.getScriptSetupValue("RADIATOR")()
        lastSetupRad = radiatorSetup
        prevRadiatorSetup = radiatorSetup
        applyRadiatorSetup(radiatorSetup)
        --overheadMessageQueue("Radiator setup SetupBits", ac.getScriptSetupValue("RADIATOR")(), 3, true)
    end

    -- Fix turbo in other sessions, than race.
    if superchargerExists == 1 and isCarInPits and ac.getSim().raceSessionType ~= ac.SessionType.Race then
        initTurboVariables(ac, printDebug)
        acCarPhysics.controllerInputs[25] = 0
        turboSmokeTimer = turboSmokeDuration
        currentEngineHeatGainMult = engineHeatGainMult
        prevFailedTurboCount = 0
    end

    -- Call the cooling damage warning resets only after body cooling damage has been fixed.
    -- For this we don't need to be in the pits. It fixes a bug where a pit
    -- stop was not correctly detected, therefore faults stayed active, even though
    -- they were fixed during the pit stop.
    if thisCar.damage[0] < 10 and thisCar.damage[2] < 10 and thisCar.damage[3] < 10  then
        hasRadiatorDamage = false
        hasRadiatorMajorDamage = false
        brakesFailed = false
        boxDamaged = false
        randomBrakeLimit = nil
    end
end--end of setupbits function

local function adjustRatesAccordingToEngineMap()
    local engineMap = thisCar.fuelMap + 1

    -- Calculate the actual failure rates using the base rates, which may have changed by e.g.
    -- overrevving, or other factors. This way the possibly modified base rates are adjusted
    -- according to the engine map factors.
    sparkPlugFailureRate = math.floor(sparkPlugFailureRateBase * sparkPlugEngineMapFactors[engineMap] + 0.5)
    fuelPumpFailureRate = math.floor(fuelPumpFailureRateBase * fuelPumpEngineMapFactors[engineMap] + 0.5)
    valveFailureRate = math.floor(valveFailureRateBase * valveEngineMapFactors[engineMap] + 0.5)
    oilPressureFailureRate = math.floor(oilPressureFailureRateBase * oilPressureEngineMapFactors[engineMap] + 0.5)

    printDebug("Engine map", EGINE_MAP_DESCRIPTIONS[engineMap])

    if DEBUG_LOG_FILE and engineMap ~= prevEngineMap then
        logDebug("Engine map: ", EGINE_MAP_DESCRIPTIONS[engineMap])
        prevEngineMap = engineMap
    end
end

local resetPitRepairQueue

-- Set everything to initial state. Useful for resetting the
-- car for a race, for example.
function resetCar(resetElectricalComponents)
    if isAICar then
        resetAIFailureSystem()
        return
    end

    if randomizeSessionFailureRates then
        randomizeSessionFailureRates()
    end

    ac.ControlButton("__EXT_ENGINEMAP_UP"):setDisabled(false)
    if resetSparkPlugFailures then
        resetSparkPlugFailures()
    else
        sparkPlugFailed = false
    end
    valveFailed = false
    valveFailureActive = false
    valveFailureElapsed = 0
    valveFailureDamage = valveFailureMinDamage
    oilPressureFailed = false
    oilPressureFailureActive = false
    oilPressureFailureElapsed = 0
    oilPressureFailureDamage = oilPressureFailureMinDamage
    resetOilPressureSystem()
    currentSpares = getCurrentSpares()
    hasRadiatorDamage = false
    brakesFailed = false
    brakeWearLevel = 0.0
    boxDamaged = false
    randomBrakeLimit = nil
    fuelPumpFailed = false
    fuelPumpRepairInProgress = false
    fuelPumpPitTimer = 0
    gearboxRepairInProgress = false
    gearboxPitTimer = 0
    oilPitRefillInProgress = false
    oilPitRefillTimer = 0
    isRepairingBelt = false
    beltRepairTimer = 0
    resetFuelTankPressurization()
    resetRadiatorDustClog()
    resetAirCoolingSystem(resetElectricalComponents ~= false)
    resetEngineCrashFire()
    initDeadGears()
    resetDoubleClutchGearbox()
    resetDogboxGearbox()
    ac.setEngineLifeLeft(1000)
    carHasTeleportedToPits = false
    resetThermalTemperaturesToAmbient()
    radiatorCoolCoefficient = radiatorCoolCoefficientInitialValue
    radiatorCoolCoefficientBase = radiatorCoolCoefficientInitialValue
    radiatorSetup = ac.getScriptSetupValue("RADIATOR")()
    prevRadiatorSetup = radiatorSetup
    applyRadiatorSetup(radiatorSetup)
    radiatorCoolCoefficient = radiatorCoolCoefficientBase
    sparkPlugFailureRate = sparkPlugFailureRateInitialValue
    sparkPlugFailureRateBase = sparkPlugFailureRateInitialValue
    fuelPumpFailureRate = fuelPumpFailureRateInitialValue
    fuelPumpFailureRateBase = fuelPumpFailureRateInitialValue
    valveFailureRate = valveFailureRateInitialValue
    valveFailureRateBase = valveFailureRateInitialValue
    oilPressureFailureRate = oilPressureFailureRateInitialValue
    oilPressureFailureRateBase = oilPressureFailureRateInitialValue
    hasEngineDamage = false
    doOnceAtStart = false

    if superchargerExists == 1 then
        initTurboVariables(ac, printDebug)
        currentEngineHeatGainMult = engineHeatGainMult
        prevFailedTurboCount = 0
        turboSmokeTimer = turboSmokeDuration
        acCarPhysics.controllerInputs[25] = 0
    end

    tyreStockEmpty = false
    resetTyreServiceState()
    initTyrePunctureTables()
    for i = 0, 3 do
        ac.setTyreInflation(i, 1.0)
    end

    initTyreWearTable()
    resetCumulativeRateChanges()

    if resetPitRepairQueue then
        resetPitRepairQueue()
    end

    if resetCVRPitCrewRoadsideServiceState then
        resetCVRPitCrewRoadsideServiceState()
    end

    if resetEngineStarter then
        resetEngineStarter()
    end

    ResetEle(resetElectricalComponents ~= false)
    rescue.reset()

    logDebug("Physics script version: ", VERSION, true)
    logDebug("Car reset done.")
    logRates()
end

-- run resetCar at each session restart
ac.onSessionStart(function()
    doOnceAtStart = false
    resetCar()
end)
-- setDisable engineMap button to false at start. just in case it did not reset properly in a previous session
ac.ControlButton("__EXT_ENGINEMAP_UP"):setDisabled(false)
-- callbacks to re-enable engineMap button
function DIH_reEnableEngineMapButton()
    ac.ControlButton("__EXT_ENGINEMAP_UP"):setDisabled(false)
end

local disposalHandle = ac.onLuaScriptDisposal(function(senderName, senderType, senderID)
    -- This runs when the script is unloaded
    DIH_reEnableEngineMapButton()
end)

ac.onRelease(DIH_reEnableEngineMapButton)
ac.onOpenMainMenu(DIH_reEnableEngineMapButton)
ac.onLuaScriptDisposal(DIH_reEnableEngineMapButton)

local inGrid = false

local PIT_REPAIR_ALTERNATOR = "alternator"
local PIT_REPAIR_FUEL_PUMP = "fuelPump"
local PIT_REPAIR_SPARK_PLUGS = "sparkPlugs"
local PIT_REPAIR_GEARBOX = "gearbox"
local PIT_REPAIR_OIL = "oil"
local PIT_REPAIR_AIR_COOLING = "airCooling"

local CVR_PIT_REPAIR_ALTERNATOR = 1
local CVR_PIT_REPAIR_FUEL_PUMP = 2
local CVR_PIT_REPAIR_SPARK_PLUGS = 4
local CVR_PIT_REPAIR_GEARBOX = 8
local CVR_PIT_REPAIR_OIL = 16
local CVR_PIT_REPAIR_AIR_COOLING = 32

local pitRepairQueue = {}
local pitRepairQueueIndex = 0
local prevPitRepairButtonState = false
local cvrPitCrewRepairConnection = nil
local cvrPitCrewOilStatusConnection = nil
local cvrPitCrewFuelStatusConnection = nil
local cvrPitCrewServiceStatusConnection = nil
local cvrPitCrewLastRepairRequestId = 0
local cvrPitCrewActiveRepairRequestId = 0
local cvrPitCrewActiveRepairMask = 0

-- Roadside services use a separate channel from the pit queue. A request is
-- always one item, so roadside work cannot accidentally start in parallel.
CVR_ROADSIDE_REPAIR_ELECTRICITY = 1
CVR_ROADSIDE_REPAIR_SPARK_PLUGS = 4
CVR_ROADSIDE_REPAIR_AIR_COOLING = 32
local CVR_ROADSIDE_STATE_READY = 0
local CVR_ROADSIDE_STATE_ARMED = 1
local CVR_ROADSIDE_STATE_WORKING = 2
local CVR_ROADSIDE_STATE_COMPLETE = 3
local CVR_ROADSIDE_STATE_REJECTED = 4
local cvrPitCrewRoadsideConnection = nil
local cvrPitCrewRoadsideLastRequestId = 0
local cvrPitCrewRoadsideActiveTyreMask = 0
local cvrPitCrewRoadsideActiveRepairMask = 0

do
    local ok, connection = pcall(ac.connect, {
        ac.StructItem.key('cvr.pitCrew.tyres.v1'),
        requestId = ac.StructItem.uint32(),
        tyreMask = ac.StructItem.uint8(),
        appliedRequestId = ac.StructItem.uint32(),
        appliedMask = ac.StructItem.uint8(),
        status = ac.StructItem.uint8(),
        carIndex = ac.StructItem.int32(),
        repairRequestId = ac.StructItem.uint32(),
        repairMask = ac.StructItem.uint8(),
        appliedRepairRequestId = ac.StructItem.uint32(),
        appliedRepairMask = ac.StructItem.uint8(),
        repairStatus = ac.StructItem.uint8(),
        repairNeededMask = ac.StructItem.uint8(),
    }, true, ac.SharedNamespace.Shared)
    if ok then
        cvrPitCrewRepairConnection = connection
    end
end

do
    local ok, connection = pcall(ac.connect, {
        ac.StructItem.key('cvr.pitCrew.roadside.v1'),
        requestId = ac.StructItem.uint32(),
        tyreMask = ac.StructItem.uint8(),
        repairMask = ac.StructItem.uint8(),
        available = ac.StructItem.boolean(),
        state = ac.StructItem.uint8(),
        availableTyreMask = ac.StructItem.uint8(),
        availableRepairMask = ac.StructItem.uint8(),
        carIndex = ac.StructItem.int32(),
    }, true, ac.SharedNamespace.Shared)
    if ok then
        cvrPitCrewRoadsideConnection = connection
    end
end

do
    local ok, connection = pcall(ac.connect, {
        ac.StructItem.key('cvr.pitCrew.status.v2'),
        carIndex = ac.StructItem.int32(),
        available = ac.StructItem.boolean(),
        tankFillFraction = ac.StructItem.float(),
        tankLeaking = ac.StructItem.boolean(),
        puncturedTyreMask = ac.StructItem.uint8(),
    }, true, ac.SharedNamespace.Shared)
    if ok then
        cvrPitCrewOilStatusConnection = connection
    end
end

do
    local ok, connection = pcall(ac.connect, {
        ac.StructItem.key('cvr.pitCrew.fuelStatus.v1'),
        carIndex = ac.StructItem.int32(),
        available = ac.StructItem.boolean(),
        tankLeaking = ac.StructItem.boolean(),
    }, true, ac.SharedNamespace.Shared)
    if ok then
        cvrPitCrewFuelStatusConnection = connection
    end
end

do
    local ok, connection = pcall(ac.connect, {
        ac.StructItem.key('cvr.pitCrew.serviceStatus.v4'),
        carIndex = ac.StructItem.int32(),
        available = ac.StructItem.boolean(),
        brakeFailure = ac.StructItem.boolean(),
        alternatorSeconds = ac.StructItem.float(),
        fuelPumpSeconds = ac.StructItem.float(),
        sparkPlugsSeconds = ac.StructItem.float(),
        gearboxSeconds = ac.StructItem.float(),
        oilSeconds = ac.StructItem.float(),
        airCoolingSeconds = ac.StructItem.float(),
        airCoolingFanDriveType = ac.StructItem.uint8(),
        electricalIssueMask = ac.StructItem.uint8(),
        oilPressureFault = ac.StructItem.boolean(),
        valveFailure = ac.StructItem.boolean(),
        sparkPlugFailure = ac.StructItem.boolean(),
        tyreSeconds = ac.StructItem.float(),
        tyreChangesCanRunWithRepairs = ac.StructItem.boolean(),
    }, true, ac.SharedNamespace.Shared)
    if ok then
        cvrPitCrewServiceStatusConnection = connection
    end
end

local function isAnyGearBrokenForPitRepair()
    if not deadGears then return false end

    for i = 1, thisCar.gearCount do
        if deadGears[i] then
            return true
        end
    end

    return false
end

local function needsAlternatorPitRepair()
    if ignitionType ~= 2 and ignitionType ~= 3 then
        return false
    end

    if batteryMaxCapacity < 75 or alternatorHealth < 0.9 then
        return true
    end

    return not alternatorOK
        or (needsAirCoolingSharedBeltService and needsAirCoolingSharedBeltService())
end

local function needsFuelPumpPitRepair()
    return not (isManualFuelPressureDriverEnabled and isManualFuelPressureDriverEnabled()) and fuelPumpFailed
end

local function needsSparkPlugPitRepair()
    return getFouledSparkPlugCount and getFouledSparkPlugCount() > 0
end

local function needsOilPitRefill()
    return oilPressureSystemNeedsPitService and oilPressureSystemNeedsPitService()
end

local function updateCVRPitCrewOilStatus()
    if not cvrPitCrewOilStatusConnection then
        return
    end

    cvrPitCrewOilStatusConnection.carIndex = thisCar.index or 0
    cvrPitCrewOilStatusConnection.available = true
    cvrPitCrewOilStatusConnection.tankFillFraction = math.max(0, math.min(1,
        (oilTankCurrentLitres or 0) / math.max(oilTankCapacityLitres or 1, 0.001)))
    cvrPitCrewOilStatusConnection.tankLeaking = oilTankLeakageDamage == true

    local puncturedTyreMask = 0
    for i = 0, 3 do
        if thisCar.wheels[i].isBlown or (tyrePunctureDeflateFactor[i] or 0) > 0 then
            puncturedTyreMask = puncturedTyreMask + 2 ^ i
        end
    end
    cvrPitCrewOilStatusConnection.puncturedTyreMask = puncturedTyreMask
end

local function updateCVRPitCrewFuelStatus()
    if not cvrPitCrewFuelStatusConnection then
        return
    end

    cvrPitCrewFuelStatusConnection.carIndex = thisCar.index or 0
    cvrPitCrewFuelStatusConnection.available = true
    cvrPitCrewFuelStatusConnection.tankLeaking = fuelLeakageDamage == true
end

local function getAirCoolingPitRepairEstimate()
    if airCoolingStatus == AIR_COOLING_STATUS_FAN_SHROUD_DAMAGED then
        return ((airCoolingFanShroudPitRepairTimeMinSeconds or 0)
            + (airCoolingFanShroudPitRepairTimeMaxSeconds or 0)) * 0.5
    end

    return ((airCoolingBeltPitRepairTimeMinSeconds or 0)
        + (airCoolingBeltPitRepairTimeMaxSeconds or 0)) * 0.5
end

local function getElectricalIssueMask()
    if ignitionType ~= 2 and ignitionType ~= 3 then
        return 0
    end

    local mask = 0
    if (batteryMaxCapacity or 100) < 75 then
        mask = mask + 1
    end
    if (alternatorHealth or 1) < 0.9 then
        mask = mask + 2
    end
    -- A shared fan/generator belt is one electrical service item. A slipping
    -- belt can still charge weakly, so it needs to be reported even before the
    -- alternator model marks charging as fully failed.
    if alternatorOK == false
        or (needsAirCoolingSharedBeltService and needsAirCoolingSharedBeltService()) then
        mask = mask + 4
    end
    return mask
end

local function hasOilPressureFaultForPitCrew()
    return oilPressurePumpDamaged == true
        or oilPressureFailed == true
        or oilPressureFailureActive == true
        or oilPressureDamageActive == true
end

local function updateCVRPitCrewServiceStatus()
    if not cvrPitCrewServiceStatusConnection then
        return
    end

    local fouledSparkPlugs = getFouledSparkPlugCount and getFouledSparkPlugCount() or 0
    cvrPitCrewServiceStatusConnection.carIndex = thisCar.index or 0
    cvrPitCrewServiceStatusConnection.available = true
    cvrPitCrewServiceStatusConnection.brakeFailure = brakesFailed == true
    cvrPitCrewServiceStatusConnection.alternatorSeconds = math.max(0, (alternatorRepairTime or 0) * 0.5)
    cvrPitCrewServiceStatusConnection.fuelPumpSeconds = math.max(0, fuelPumpRepairTime or 0)
    cvrPitCrewServiceStatusConnection.sparkPlugsSeconds = fouledSparkPlugs > 0
        and math.max(0, (sparkPlugPitChangeFirstPlugSeconds or 0)
            + (fouledSparkPlugs - 1) * (sparkPlugPitChangeAdditionalPlugSeconds or 0))
        or 0
    cvrPitCrewServiceStatusConnection.gearboxSeconds = math.max(0, gearboxRepairTime or 0)
    cvrPitCrewServiceStatusConnection.oilSeconds = math.max(0, oilPitRefillTimeSeconds or 0)
    cvrPitCrewServiceStatusConnection.airCoolingSeconds = math.max(0, getAirCoolingPitRepairEstimate())
    cvrPitCrewServiceStatusConnection.airCoolingFanDriveType = (isAirCoolingSystemEnabled and isAirCoolingSystemEnabled()
        and getAirCoolingFanDriveType and getAirCoolingFanDriveType()) or 0
    cvrPitCrewServiceStatusConnection.electricalIssueMask = getElectricalIssueMask()
    cvrPitCrewServiceStatusConnection.oilPressureFault = hasOilPressureFaultForPitCrew()
    cvrPitCrewServiceStatusConnection.valveFailure = valveFailed == true or valveFailureActive == true
    cvrPitCrewServiceStatusConnection.sparkPlugFailure = fouledSparkPlugs > 0
    cvrPitCrewServiceStatusConnection.tyreSeconds = getCVRPitCrewTyreChangeTime
        and math.max(0, getCVRPitCrewTyreChangeTime(1)) or 0
    cvrPitCrewServiceStatusConnection.tyreChangesCanRunWithRepairs = pitTyreChangesCanRunWithRepairs ~= false
end

local function pitRepairQueueIsActive()
    return pitRepairQueueIndex > 0 and pitRepairQueueIndex <= #pitRepairQueue
end

function isCustomPitRepairQueueActive()
    return pitRepairQueueIsActive()
end

function isPitRepairQueueCurrent(repairType)
    return pitRepairQueueIsActive() and pitRepairQueue[pitRepairQueueIndex] == repairType
end

function completePitRepairQueueItem(repairType)
    if not isPitRepairQueueCurrent(repairType) then
        return
    end

    pitRepairQueueIndex = pitRepairQueueIndex + 1
    if not pitRepairQueueIsActive() then
        pitRepairQueue = {}
        pitRepairQueueIndex = 0
        overheadMessageQueue("Pit repairs", "Service queue complete", 3, true)
    end
end

resetPitRepairQueue = function()
    pitRepairQueue = {}
    pitRepairQueueIndex = 0
    prevPitRepairButtonState = false
end

local function queuePitRepair(repairType)
    pitRepairQueue[#pitRepairQueue + 1] = repairType
end

local function repairMaskHas(mask, bit)
    return math.floor((mask or 0) / bit) % 2 == 1
end

local function queueSelectedPitRepair(bit, mask, repairType, needsRepair)
    if repairMaskHas(mask, bit) and needsRepair then
        queuePitRepair(repairType)
        return bit
    end

    return 0
end

local function getNeededPitRepairMask()
    local mask = 0
    if needsAlternatorPitRepair() then
        mask = mask + CVR_PIT_REPAIR_ALTERNATOR
    end
    if needsFuelPumpPitRepair() then
        mask = mask + CVR_PIT_REPAIR_FUEL_PUMP
    end
    if needsSparkPlugPitRepair() then
        mask = mask + CVR_PIT_REPAIR_SPARK_PLUGS
    end
    if isAnyGearBrokenForPitRepair() then
        mask = mask + CVR_PIT_REPAIR_GEARBOX
    end
    if needsOilPitRefill() then
        mask = mask + CVR_PIT_REPAIR_OIL
    end
    if needsAirCoolingPitRepair and needsAirCoolingPitRepair() then
        mask = mask + CVR_PIT_REPAIR_AIR_COOLING
    end
    return mask
end

local function firstMaskBit(mask)
    local bit = 1
    while bit <= 128 do
        if repairMaskHas(mask, bit) then
            return bit
        end
        bit = bit * 2
    end
    return 0
end

local function intersectRepairMasks(firstMask, secondMask)
    local intersection = 0
    local bit = 1
    while bit <= 128 do
        if repairMaskHas(firstMask, bit) and repairMaskHas(secondMask, bit) then
            intersection = intersection + bit
        end
        bit = bit * 2
    end
    return intersection
end

local function getCVRPitCrewRoadsideTyreMask()
    local mask = 0
    if currentSpares == 0 then
        return mask
    end
    for tyreIndex = 0, 3 do
        if thisCar.wheels[tyreIndex].isBlown or (tyrePunctureDeflateFactor[tyreIndex] or 0) > 0 then
            mask = mask + 2 ^ tyreIndex
        end
    end
    return mask
end

local function getCVRPitCrewRoadsideRepairMask()
    local mask = 0
    if (not alternatorOK) or (needsAirCoolingSharedBeltService and needsAirCoolingSharedBeltService()) then
        mask = mask + CVR_ROADSIDE_REPAIR_ELECTRICITY
    end
    if getFouledSparkPlugCount and getFouledSparkPlugCount() > 0 then
        mask = mask + CVR_ROADSIDE_REPAIR_SPARK_PLUGS
    end
    if airCoolingUsesFanBelt and airCoolingUsesFanBelt()
            and not (airCoolingSharesGeneratorBelt and airCoolingSharesGeneratorBelt())
            and (airCoolingStatus == AIR_COOLING_STATUS_BELT_SLIPPING
                or airCoolingStatus == AIR_COOLING_STATUS_BELT_BROKEN) then
        mask = mask + CVR_ROADSIDE_REPAIR_AIR_COOLING
    end
    return mask
end

function isCVRPitCrewRoadsideTyreRequested(tyreIndex)
    return repairMaskHas(cvrPitCrewRoadsideActiveTyreMask, 2 ^ tyreIndex)
end

function isCVRPitCrewRoadsideRepairRequested(repairBit)
    return repairMaskHas(cvrPitCrewRoadsideActiveRepairMask, repairBit)
end

function beginCVRPitCrewRoadsideService()
    if cvrPitCrewRoadsideConnection
            and (cvrPitCrewRoadsideActiveTyreMask > 0 or cvrPitCrewRoadsideActiveRepairMask > 0) then
        cvrPitCrewRoadsideConnection.state = CVR_ROADSIDE_STATE_WORKING
    end
end

function completeCVRPitCrewRoadsideTyreService(tyreIndex)
    if not isCVRPitCrewRoadsideTyreRequested(tyreIndex) then
        return
    end

    cvrPitCrewRoadsideActiveTyreMask = 0
    if cvrPitCrewRoadsideConnection then
        cvrPitCrewRoadsideConnection.state = CVR_ROADSIDE_STATE_COMPLETE
    end
end

function completeCVRPitCrewRoadsideRepairService(repairBit)
    if not isCVRPitCrewRoadsideRepairRequested(repairBit) then
        return
    end

    cvrPitCrewRoadsideActiveRepairMask = 0
    if cvrPitCrewRoadsideConnection then
        cvrPitCrewRoadsideConnection.state = CVR_ROADSIDE_STATE_COMPLETE
    end
end

function cancelCVRPitCrewRoadsideService()
    if cvrPitCrewRoadsideActiveTyreMask == 0 and cvrPitCrewRoadsideActiveRepairMask == 0 then
        return
    end

    cvrPitCrewRoadsideActiveTyreMask = 0
    cvrPitCrewRoadsideActiveRepairMask = 0
    if cvrPitCrewRoadsideConnection then
        cvrPitCrewRoadsideConnection.state = CVR_ROADSIDE_STATE_REJECTED
    end
end

function resetCVRPitCrewRoadsideServiceState()
    cvrPitCrewRoadsideActiveTyreMask = 0
    cvrPitCrewRoadsideActiveRepairMask = 0
    if cvrPitCrewRoadsideConnection then
        cvrPitCrewRoadsideLastRequestId = tonumber(cvrPitCrewRoadsideConnection.requestId) or 0
        cvrPitCrewRoadsideConnection.tyreMask = 0
        cvrPitCrewRoadsideConnection.repairMask = 0
        cvrPitCrewRoadsideConnection.state = CVR_ROADSIDE_STATE_READY
    end
end

local function updateCVRPitCrewRoadsideService()
    if not cvrPitCrewRoadsideConnection then
        return
    end

    local connection = cvrPitCrewRoadsideConnection
    connection.carIndex = thisCar.index or 0
    connection.available = true
    connection.availableTyreMask = getCVRPitCrewRoadsideTyreMask()
    connection.availableRepairMask = getCVRPitCrewRoadsideRepairMask()

    if isCarInPits then
        cancelCVRPitCrewRoadsideService()
        connection.state = CVR_ROADSIDE_STATE_READY
        return
    end

    local speedKmh = thisCar.speedKmh or 0
    if (cvrPitCrewRoadsideActiveTyreMask > 0 or cvrPitCrewRoadsideActiveRepairMask > 0)
            and speedKmh > 2 then
        cancelCVRPitCrewRoadsideService()
        return
    end

    if cvrPitCrewRoadsideActiveTyreMask > 0 or cvrPitCrewRoadsideActiveRepairMask > 0 then
        return
    end

    local requestId = tonumber(connection.requestId) or 0
    if requestId == 0 or requestId == cvrPitCrewRoadsideLastRequestId then
        return
    end
    cvrPitCrewRoadsideLastRequestId = requestId

    local requestedTyres = firstMaskBit(intersectRepairMasks(
        tonumber(connection.tyreMask) or 0, tonumber(connection.availableTyreMask) or 0))
    local requestedRepairs = firstMaskBit(intersectRepairMasks(
        tonumber(connection.repairMask) or 0, tonumber(connection.availableRepairMask) or 0))
    if speedKmh >= 1 or (requestedTyres == 0 and requestedRepairs == 0)
            or (requestedTyres > 0 and requestedRepairs > 0) then
        connection.state = CVR_ROADSIDE_STATE_REJECTED
        return
    end

    cvrPitCrewRoadsideActiveTyreMask = requestedTyres
    cvrPitCrewRoadsideActiveRepairMask = requestedRepairs
    connection.state = CVR_ROADSIDE_STATE_ARMED
end

local function updateCVRPitCrewRepairStatus()
    if not cvrPitCrewRepairConnection or cvrPitCrewActiveRepairRequestId == 0 or pitRepairQueueIsActive() then
        return
    end

    cvrPitCrewRepairConnection.appliedRepairRequestId = cvrPitCrewActiveRepairRequestId
    cvrPitCrewRepairConnection.appliedRepairMask = cvrPitCrewActiveRepairMask
    cvrPitCrewRepairConnection.repairStatus = cvrPitCrewActiveRepairMask > 0 and 1 or 2
    cvrPitCrewActiveRepairRequestId = 0
    cvrPitCrewActiveRepairMask = 0
end

local function updateCVRPitCrewRepairQueue()
    updateCVRPitCrewOilStatus()
    updateCVRPitCrewFuelStatus()
    updateCVRPitCrewServiceStatus()

    if not cvrPitCrewRepairConnection then
        return
    end

    cvrPitCrewRepairConnection.repairNeededMask = getNeededPitRepairMask()

    if not isCarInPits then
        cvrPitCrewRepairConnection.repairStatus = 0
        cvrPitCrewActiveRepairRequestId = 0
        cvrPitCrewActiveRepairMask = 0
        cvrPitCrewLastRepairRequestId = 0
        return
    end

    updateCVRPitCrewRepairStatus()

    if pitRepairQueueIsActive() or cvrPitCrewActiveRepairRequestId ~= 0
            or (pitTyreChangesCanRunWithRepairs == false
                and isCVRPitCrewTyreServiceActive and isCVRPitCrewTyreServiceActive()) then
        return
    end

    local requestId = tonumber(cvrPitCrewRepairConnection.repairRequestId) or 0
    local repairMask = tonumber(cvrPitCrewRepairConnection.repairMask) or 0
    if requestId == 0 or requestId == cvrPitCrewLastRepairRequestId or repairMask == 0 then
        return
    end

    pitRepairQueue = {}
    pitRepairQueueIndex = 0
    local appliedMask = 0

    appliedMask = appliedMask + queueSelectedPitRepair(CVR_PIT_REPAIR_ALTERNATOR, repairMask, PIT_REPAIR_ALTERNATOR, needsAlternatorPitRepair())
    appliedMask = appliedMask + queueSelectedPitRepair(CVR_PIT_REPAIR_FUEL_PUMP, repairMask, PIT_REPAIR_FUEL_PUMP, needsFuelPumpPitRepair())
    appliedMask = appliedMask + queueSelectedPitRepair(CVR_PIT_REPAIR_SPARK_PLUGS, repairMask, PIT_REPAIR_SPARK_PLUGS, needsSparkPlugPitRepair())
    appliedMask = appliedMask + queueSelectedPitRepair(CVR_PIT_REPAIR_GEARBOX, repairMask, PIT_REPAIR_GEARBOX, isAnyGearBrokenForPitRepair())
    appliedMask = appliedMask + queueSelectedPitRepair(CVR_PIT_REPAIR_OIL, repairMask, PIT_REPAIR_OIL, needsOilPitRefill())
    appliedMask = appliedMask + queueSelectedPitRepair(CVR_PIT_REPAIR_AIR_COOLING, repairMask, PIT_REPAIR_AIR_COOLING, needsAirCoolingPitRepair and needsAirCoolingPitRepair())

    cvrPitCrewLastRepairRequestId = requestId
    cvrPitCrewActiveRepairRequestId = requestId
    cvrPitCrewActiveRepairMask = appliedMask
    cvrPitCrewRepairConnection.appliedRepairRequestId = 0
    cvrPitCrewRepairConnection.appliedRepairMask = appliedMask

    if appliedMask > 0 then
        pitRepairQueueIndex = 1
        cvrPitCrewRepairConnection.repairStatus = 3
        overheadMessageQueue("Pit repairs", "Selected service queue started", 3, true)
    else
        cvrPitCrewRepairConnection.appliedRepairRequestId = requestId
        cvrPitCrewRepairConnection.repairStatus = 2
        cvrPitCrewActiveRepairRequestId = 0
    end
end

local function updatePitRepairQueue()
    if not isCarInPits then
        resetPitRepairQueue()
        updateCVRPitCrewRepairQueue()
        return
    end

    updateCVRPitCrewRepairQueue()

    if pitRepairQueueIsActive()
            or (pitTyreChangesCanRunWithRepairs == false
                and isCVRPitCrewTyreServiceActive and isCVRPitCrewTyreServiceActive()) then
        return
    end

    if thisCar.extraB and not prevPitRepairButtonState then
        pitRepairQueue = {}
        pitRepairQueueIndex = 0

        if needsAlternatorPitRepair() then
            queuePitRepair(PIT_REPAIR_ALTERNATOR)
        end
        if needsFuelPumpPitRepair() then
            queuePitRepair(PIT_REPAIR_FUEL_PUMP)
        end
        if needsSparkPlugPitRepair() then
            queuePitRepair(PIT_REPAIR_SPARK_PLUGS)
        end
        if isAnyGearBrokenForPitRepair() then
            queuePitRepair(PIT_REPAIR_GEARBOX)
        end
        if needsOilPitRefill() then
            queuePitRepair(PIT_REPAIR_OIL)
        end
        if needsAirCoolingPitRepair and needsAirCoolingPitRepair() then
            queuePitRepair(PIT_REPAIR_AIR_COOLING)
        end

        if #pitRepairQueue > 0 then
            pitRepairQueueIndex = 1
            overheadMessageQueue("Pit repairs", "Service queue started", 3, true)
        end
    end

    prevPitRepairButtonState = thisCar.extraB
end

-- MAIN UPDATE STARTS
function update(dt)
    if isAICar then
        updateAIFailureSystem(dt)
        return
    end

    inGrid = (ac.getSim().raceSessionType == ac.SessionType.Race and not ac.getSim().isSessionStarted)
    updateLastCarWorldPosition()

    if thisCar.isInPit or inGrid or (dt < 0.0001) or ac.getSim().isInMainMenu or ac.getSim().isPaused then
        ac.ControlButton("__EXT_ENGINEMAP_UP"):setDisabled(false)
    end

    if currentSpares ~= 0 then
        tyreStockEmpty = false
    end
    if TEST_CODE then
        updateScriptSetupToggles()
        selectFailureForTesting()
        setFailureForTesting()
    end

    -- Pit crew work is allowed only while physically in the pit box. The old
    -- latched value remained true through the rest of the pit lane.
    isCarInPits = thisCar.isInPit and true or false
    printDebug("isCarInPits", isCarInPits)
    updateCVRPitCrewRoadsideService()

    if ac.getSim().inputMode == ac.UserInputMode.Wheel
            and acCarPhysics.inputMethod == ac.InputMethod.Wheel then
        new_throttle_model.runTM()
    end
    applyEngineTemperaturePower(dt)

    logExtraButtonPresses()
    logCarEnterAndLeavePits()
    updatePitRepairQueue()
    if DEBUG then
        updateZeroToHundredDebugTimer(dt)
    end

    if not (thisCar.isInPit or inGrid or (dt < 0.0001) or ac.getSim().isInMainMenu or ac.getSim().isPaused) then
        rescue.update(dt)
    end

    optimizationTimer = optimizationTimer + dt

    brakeWear(dt)
    fuelPumpFailure(dt)
    updateSparkPlugPowerLoss()
    updateFuelTankPressurization(dt)
    setupBits(dt)
    updateCVRPitCrewTyreOverrides()
    coolantBehavior(dt)
    updateAirCoolingSystem(dt)
    updateEngineCrashFire(dt)
    tyreReplacement(dt)
    overheadMessageDisplay(dt)
    engineStaller(dt)
    updateOilPressureSystem(dt)
    updateDoubleClutchGearbox(dt)
    updateDogboxGearbox(dt)

    if (ignitionType == 2) or (ignitionType == 3) then

        updateElectricity(dt)
        handleRepairs(dt, overheadMessageQueue)

        debugElectricity(dt)  -- <-- added

        if thisCar.isInPit and isPitRepairQueueCurrent(PIT_REPAIR_ALTERNATOR) then
            if not needsAlternatorPitRepair() then
                isRepairingBelt = false
                beltRepairTimer = 0
                acCarPhysics.controllerInputs[52] = 0
                completePitRepairQueueItem(PIT_REPAIR_ALTERNATOR)
            elseif not isRepairingBelt then
                isRepairingBelt = true
                beltRepairTimer = 0  -- Reset timer when repair starts
                overheadMessageQueue("Electricity", "Service started. Hold position until done", 3, true)
                printDebug("Electricity", "Repair process started")
            end

            -- If repair is in progress, count time
            if isRepairingBelt then
                beltRepairTimer = beltRepairTimer + dt

                -- todo: adjust batteryMaxCapacity based on what is the problem. new battery - for simplicity I'll just assume they check and replace everything

                -- Keep repair progress on the single queued overhead channel.
                overheadMessageQueue(
                    "Electricity",
                    "Progress: " .. string.format("%d%%", math.floor((beltRepairTimer / (alternatorRepairTime / 2)) * 100)),
                    1,
                    true)
                printDebug("Electricity progress", string.format("%.1f sec left", (alternatorRepairTime/2) - beltRepairTimer))

                -- When repair time has passed, complete the repair
                if beltRepairTimer >= (alternatorRepairTime/2) then
                    alternatorOK = true
                    alternatorHealth = 1.0
                    if repairAirCoolingSharedBelt then
                        repairAirCoolingSharedBelt()
                    end
                    beltRepairTimer = 0
                    isRepairingBelt = false
                    acCarPhysics.controllerInputs[52] = 0
                    alternatorRepairTime = math.random(100, 200)
                    batteryCurrentCharge = 100
                    batteryMaxCapacity = 100
                    overheadMessageQueue("Electricity", "Service complete", 3, true)
                    completePitRepairQueueItem(PIT_REPAIR_ALTERNATOR)
                end
            end
        elseif isRepairingBelt then
            isRepairingBelt = false
            beltRepairTimer = 0
            acCarPhysics.controllerInputs[52] = 0
        end
    end

    sparkPlugRoadsideRepair(dt)

    mediumSpeedDtTimer = mediumSpeedDtTimer + dt

    if mediumSpeedDtTimer >= 0.1 then
        slowTyrePuncture()
        fuelExhaustion()
        limitEngineDamageAtCrash()
        mediumSpeedDtTimer = 0
    end

    if fuelExhCutLength > 0 then
        if fuelExhCutTimer < fuelExhCutLength then
            acCarPhysics.gas = math.min(acCarPhysics.gas or 0, math.random() * 0.2)
            fuelExhCutTimer = fuelExhCutTimer + dt
        else
            fuelExhCutLength = 0
            fuelExhCutTimer = 0
        end
    end

    if superchargerExists == 1 then
        turboFailureTimer = turboFailureTimer + dt

        if not isCarInPits and turboFailureTimer >= 1 then
            if (acCarPhysics.rpm > 100) then
                updateTurboState(logDebug)
            end
            if isTurboFailureEngineOverheatingActive() then
                currentEngineHeatGainMult = engineHeatGainMultTurbo
                printDebug("Turbo", "Engine overheating active")
            end
            turboFailureTimer = 0
        end
    end

    tyreBlowCrashingTimer = tyreBlowCrashingTimer + dt

    if tyreBlowCrashingTimer >= 0.2 then
        tyreBlowWhenCrashing()
        tyreBlowCrashingTimer = 0
    end

    -- Enable/disable turbo, if the option is available.
    if turboOnOffButtonEnabled then
        if thisCar.extraD and not prevExtraDState then
            turboEnabled = not turboEnabled
            enableTurbo(turboEnabled)

            if turboEnabled then
                overheadMessageQueue("Turbo enabled", "", 3)
            else
                overheadMessageQueue("Turbo disabled", "", 3)
            end
        end
        prevExtraDState = thisCar.extraD
    end

    -- enable/disable remote fuel mix change based on flags (move to optimizeTimer part maybe?)
    if remFlags.fuelMix or thisCar.isInPit or inGrid or (dt < 0.0001) or ac.getSim().isInMainMenu or ac.getSim().isPaused then
        ac.ControlButton("__EXT_ENGINEMAP_UP"):setDisabled(false)
    else
        ac.ControlButton("__EXT_ENGINEMAP_UP"):setDisabled(true)
    end
    --

    -- radiator setup
    if radiatorShutterAdjustEnabled and ((remFlags.radiatorShutter) or thisCar.isInPit) then
        if thisCar.extraE and not prevextraEState then
            radiatorSetup = (radiatorSetup + 1) % 5
        end
        if thisCar.extraF and not prevextraFState then
            radiatorSetup = (radiatorSetup - 1) % 5
        end
        if radiatorSetup ~= prevRadiatorSetup then
            local shutterMsg = applyRadiatorSetup(radiatorSetup)
            overheadMessageQueue(getCoolingSetupTitle(), shutterMsg, 3, true)
            printDebug(getCoolingSetupTitle(), tostring(radiatorSetup))
            logDebug(getCoolingSetupTitle(), ": ", tostring(radiatorSetup))
        end
        prevextraEState = thisCar.extraE
        prevextraFState = thisCar.extraF
        prevRadiatorSetup = radiatorSetup
    end

    failureRateHandlingTimer = failureRateHandlingTimer + dt

    local physicsSpeedKmh = acCarPhysics.speedKmh or thisCar.speedKmh or 0
    if failureRateHandlingTimer >= failureRateHandlingInterval and physicsSpeedKmh > 1 then
        local rates = {
            sparkPlug = sparkPlugFailureRateBase,
            fuelPump = fuelPumpFailureRateBase,
            valveDamage = valveFailureRateBase,
            oilPressure = oilPressureFailureRateBase
        }

        local rpmRounded = math.floor((acCarPhysics.rpm or thisCar.rpm or 0) + 0.5)
        handleOverrevving(rates, rpmRounded)
        local lowRpm = handleLowRpm(rates, rpmRounded)
        local runningCloseStep = handleRunningCloseToCarInFront(rates, physicsSpeedKmh, ac)
        handleHighCoolantTemp(rates, getThermalStressTemperature())
        handleRunningTankLow(rates, thisCar.fuel)
        radiatorCoolCoefficient = handleRadiatorEfficiency(
            radiatorCoolCoefficientBase,
            lowRpm,
            runningCloseStep,
            trackSurfaceType,
            physicsSpeedKmh,
            failureRateHandlingInterval)

        sparkPlugFailureRateBase = rates.sparkPlug
        fuelPumpFailureRateBase = rates.fuelPump
        valveFailureRateBase = rates.valveDamage
        oilPressureFailureRateBase = rates.oilPressure

        printDebug("Spark plug failure rate", sparkPlugFailureRate)
        printDebug("Fuel pump failure rate", fuelPumpFailureRate)
        printDebug("Valve failure rate", valveFailureRate)
        printDebug("Oil pressure failure rate", oilPressureFailureRate)
        printDebug("radiatorCoolCoefficient", radiatorCoolCoefficient)

        failureRateHandlingTimer = 0
    end

    if DEBUG_LOG_FILE then
        ac.setLogSilent(false)

        if thisCar.lapCount ~= prevLapCount then
            if ac.getSim().raceFlagType == ac.FlagType.Finished then
                logDebug("*** SESSION FINISHED ***")
            else
                logDebug("* LAP COMPLETED *")
            end

            logDebugDataToFile()
            logDebug("***")
            prevLapCount = thisCar.lapCount
        end
    end

    if fuelPumpRepairInProgress or gearboxRepairInProgress or oilPitRefillInProgress
            or sparkPlugRepairInProgress or sparkPlugRoadsideRepairInProgress
            or isRepairingBelt or airCoolingPitRepairInProgress or airCoolingRoadsideRepairInProgress
            or thisCar.isRepairing then
        ac.setEngineRPM(0)
    end

    --run some bits only every few ticks, no point in checking them every tick.
    if optimizationTimer > 2 then
        --setExtraMass call is free if the position and mass is the same as last call, so this is fine here.
        
        if currentSpares > 0 then
            local currentSparesBugfix = currentSpares + 0.1
            ac.setExtraMass(spareWheelPos, currentSparesBugfix * spareWheelMass, vec3(0.05,0.05,0.05))
        end

        -- Prior starting the race, reset all possible failures and wear
        -- accumulated in previous (practice) sessions.
        if inGrid then
            if not doOnceAtStart then
                resetCar()
                logStaticInfo()
                doOnceAtStart = true
            end
        else
            tyreBlow()
            if (acCarPhysics.rpm > 100) then
                fuelPumpFailureActivation()
            end
            updateTyreWear()
        end

        adjustRatesAccordingToEngineMap()

        printDebug("Engine life left", acCarPhysics.engineLifeLeft)
        if acCarPhysics.engineLifeLeft < 1000 then
            hasEngineDamage = true
        end

        -- Only run failure checks when NOT in repair state
        if not gearboxRepairInProgress and not isCarInPits and not inGrid then
            if (acCarPhysics.rpm > 100) then
                sparkPlugFailure()
                valveFailure(dt)
                oilPressureFailure(dt)
                if not ac.getSim().controlsWithShifter then  -- added so the old method runs for paddle shifters only
                    gearboxFailure()
                end
            end
            --fuelTankDamage() -- once should be enough an it'S already being called right below
        end

        fuelTankDamage()

        local deadGearCount = 0
        for i = 1, thisCar.gearCount do
            if deadGears[i] then deadGearCount = deadGearCount + 1 end
        end
        local gearboxDamage = deadGearCount / thisCar.gearCount
        updateGearFailureRate(gearboxDamage)

        optimizationTimer = 0
    end

    -- new h-shifter gearbox failure system. Based on gearGrind state. needs to be outside of the optimization timer because otherwise one would potentially miss the window where this should apply
    if (thisCar.isGearGrinding or isDoubleClutchGearGrinding()) and ac.getSim().controlsWithShifter then  -- added so the old method runs for paddle shifters only
        gearboxFailureHshifter(dt)
    end

    fuelPumpPitRepair(dt)

    sparkPlugPitRepair(dt)

    gearboxPitRepair(dt)

    oilPressureSystemPitRefill(dt)

    -- Limit the minimum failure rates.
    if sparkPlugFailureRateBase < sparkPlugFailureRateMinimumValue then
        sparkPlugFailureRateBase = sparkPlugFailureRateMinimumValue
    end
    if fuelPumpFailureRateBase < fuelPumpFailureRateMinimumValue then
        fuelPumpFailureRateBase = fuelPumpFailureRateMinimumValue
    end
    if valveFailureRateBase < valveFailureRateMinimumValue then
        valveFailureRateBase = valveFailureRateMinimumValue
    end
    if oilPressureFailureRateBase < oilPressureFailureRateMinimumValue then
        oilPressureFailureRateBase = oilPressureFailureRateMinimumValue
    end

    -- Avoid calling printDebug() at every iteration in normal use,
    -- since function calls are pretty expensive in Lua.
    if DEBUG then
        -- local tyreName = ac.getTyresName(0, -1)
        --printDebug("TyreName", tyreName)

        printDebug("Extra Buttons", string.format("A: %s | B: %s", tostring(thisCar.extraA), tostring(thisCar.extraB)))

        printDebug("Cooling", string.format(
            "Damage: %.1f | Display temp: %.1f°C | Engine: %.1f°C | Clog: %.1f%% | Clog cooling loss: %.1f%%",
            carDamageClamp,
            coolantTemp,
            engineTemp,
            (radiatorDustClogLevel or 0) * 100,
            (radiatorDustClogLevel or 0) * (radiatorDustClogMaxCoolingLoss or 0) * 100))
        printDebug("Thermal low RPM cooling", string.format("%.2f", tonumber(thermalLowRpmCoolingMultiplier) or 1))
        printDebug("Air cooling", string.format(
            "Type: %s | Drive: %s | Status: %s | Fan eff: %.0f%% | Gen eff: %.0f%% | Stress: %.2f | Repair: %s %.0f%%",
            (isAirCoolingSystemEnabled and isAirCoolingSystemEnabled()) and "Air" or "Radiator",
            getAirCoolingFanDriveDescription and getAirCoolingFanDriveDescription() or "N/A",
            getAirCoolingStatusDescription and getAirCoolingStatusDescription() or "N/A",
            ((getAirCoolingFanEfficiency and getAirCoolingFanEfficiency()) or 1) * 100,
            ((getAirCoolingGeneratorEfficiency and getAirCoolingGeneratorEfficiency()) or 1) * 100,
            tonumber(airCoolingBeltStress) or 0,
            tostring((airCoolingPitRepairInProgress or airCoolingRoadsideRepairInProgress) == true),
            ((airCoolingRepairTime or 0) > 0 and math.clamp((airCoolingRepairTimer or 0) / airCoolingRepairTime, 0, 1) or 0) * 100))
        printDebug("Air cooling apps", string.format(
            "73:%s | 74:%s | 75:%.2f | 76:%.2f | 77:%.2f | 78:%s | 79:%.2f",
            tostring(acCarPhysics.controllerInputs[73]),
            tostring(acCarPhysics.controllerInputs[74]),
            tonumber(acCarPhysics.controllerInputs[75]) or 0,
            tonumber(acCarPhysics.controllerInputs[76]) or 0,
            tonumber(acCarPhysics.controllerInputs[77]) or 0,
            tostring(acCarPhysics.controllerInputs[78]),
            tonumber(acCarPhysics.controllerInputs[79]) or 0))
        printDebug("Tyres", string.format("Spares: %s | Time: %.2f", tostring(currentSpares), carStoppedTimer))
        printDebug("Brake Damage", brakesFailed)
        printDebug("Gearbox Failure", "Status: " .. tostring(isGearboxFailed))
        printDebug("Gearbox Ratio", acCarPhysics.gearsFinalRatio)
        printDebug("Gearbox", string.format("Damage: %.1f | Rate: %.1f", thisCar.gearboxDamage, boostedGearFailureRate))
        printDebug("Repair times", string.format("Fuel pump: %s | Gearbox: %s", fuelPumpRepairTime, gearboxRepairTime))
        printDebug("Valve Failure", string.format(
        "RPM: %d | Progress: %.1f%% | Damage: %.1f/%.1f | Status: %s",
            acCarPhysics.rpm,
            (valveFailureElapsed/valveFailureBaseTime)*100,
            valveFailureDamage,
            valveFailureMaxDamage,
            tostring(valveFailureActive)
        ))
        printDebug("Oil pressure problems", string.format(
        "RPM: %d | Progress: %.1f%% | Damage: %.1f/%.1f | Status: %s",
        tonumber(acCarPhysics.rpm) or 0,
        (tonumber(oilPressureFailureElapsed) or 0) / (tonumber(oilPressureFailureBaseTime) or 1) * 100,
        tonumber(oilPressureFailureDamage) or 0,
        tonumber(oilPressureFailureMaxDamage) or 1,
        tostring(oilPressureFailureActive)
    ))
        printDebug("Oil system", string.format(
        "Pressure: %.1f psi | Tank: %.2f L | Gallery: %.3f L | Pump: %s",
        tonumber(oilPressurePsi) or 0,
        tonumber(oilTankCurrentLitres) or 0,
        tonumber(oilEngineGalleryLitres) or 0,
        tostring(oilManualPumpIsActive)
    ))

        printDebug("Fuel Pump failure", string.format(
            "Gas: %.3f | Fuel flows: %.1f%% | Status: %s",
            tonumber(acCarPhysics.gas) or 0,  -- Ensuring gas is a number, default to 0 if nil
            tonumber(fuelPumpFailureCooldown) or 0,  -- Ensure a valid number (module-local; shows 0 in debug)
            tostring(fuelPumpFailed) -- Convert boolean/nil to string safely
        ))
        printDebug("Fuel Tank Pressure", string.format(
            "Enabled: %s | Pressure: %.2f psi | Pump: %s | Low: %s | Cut: %s",
            tostring(manualFuelPressurizationEnabled),
            tonumber(fuelTankPressurePsi) or 0,
            tostring(fuelTankPressurizationPumpActive),
            tostring(fuelTankPressureLow),
            tostring(fuelTankPressureFuelCutActive)
        ))
        printDebug("Spark plugs", string.format(
            "Fouled: %d/%d | Dead cylinders: %d | Repair: %s | Roadside: %s",
            getFouledSparkPlugCount(),
            getSparkPlugTotalCount(),
            getDeadSparkCylinderCount(),
            tostring(sparkPlugRepairInProgress),
            tostring(sparkPlugRoadsideRepairInProgress)
        ))
        --printDebug("Fuel Pump Repair", string.format("[%-30s] %.1f sec left", string.rep("#", (fuelPumpPitTimer / fuelPumpRepairTime) * 30), fuelPumpRepairTime - fuelPumpPitTimer))

        local currGearIndex = getCurrentGearIndex()
        printDebug("Gearbox Status", "Gear " .. currGearIndex .. ": " .. tostring(deadGears[currGearIndex]))
        printDebug("Fuel Pump", "Active: " .. tostring(fuelPumpFailed))
    end

    -- PSG update loop
    if isWilsonPreselectorGearboxEnabled() then

        if not psgInitialized then
            initPSG(ac, overheadMessageQueue)
            psgInitialized = true
        end

        updatePSG(dt,thisCar)
    end

    updateFailedGearEffect(dt)

    acCarPhysics.controllerInputs[2] = currentSpares
    acCarPhysics.controllerInputs[4] = brakesFailed
    acCarPhysics.controllerInputs[7] = oilPressureFailureActive
    acCarPhysics.controllerInputs[8] = valveFailureActive
    acCarPhysics.controllerInputs[9] = fuelPumpFailed
    acCarPhysics.controllerInputs[10] = sparkPlugFailed
    acCarPhysics.controllerInputs[12] = gearboxRepairInProgress
    acCarPhysics.controllerInputs[13] = fuelPumpRepairInProgress
    acCarPhysics.controllerInputs[14] = isAnyGearBroken()
    acCarPhysics.controllerInputs[15] = hasRadiatorDamage or hasRadiatorMajorDamage
    acCarPhysics.controllerInputs[16] = isAnyTyrePunctured()
    acCarPhysics.controllerInputs[17] = tyreStockEmpty
    acCarPhysics.controllerInputs[20] = ac.getAltitude()
    acCarPhysics.controllerInputs[21] = acCarPhysics.airDensity
    acCarPhysics.controllerInputs[22] = superchargerExists
    acCarPhysics.controllerInputs[23] = isAboveBoostLimit()

    if not isCarInPits and superchargerExists == 1 then
        local currentFailedTurboCount = getFailedTurboCount()
        acCarPhysics.controllerInputs[24] = currentFailedTurboCount

        if currentFailedTurboCount > prevFailedTurboCount then
            if turboSmokeTimer < turboSmokeDuration then
                acCarPhysics.controllerInputs[25] = 0
            end
            turboSmokeTimer = 0
        end

        prevFailedTurboCount = currentFailedTurboCount

        if turboSmokeTimer < turboSmokeDuration then
            turboSmokeTimer = turboSmokeTimer + dt
        end

        if turboSmokeTimer < turboSmokeDuration then
            -- Delay the sound a bit, otherwise if another supercharger
            -- explodes during the `turboSmokeDuration` time, then
            -- the event wouldn't be caught in `supercharger.lua`.
            if turboSmokeTimer > 0.5 then
                acCarPhysics.controllerInputs[25] = 1
            end
        else
            acCarPhysics.controllerInputs[25] = 0
        end

        printDebug("turboSmokeTimer", "" .. turboSmokeTimer)
    end

    if resetBrakeWearAtTyreChange == nil then
        acCarPhysics.controllerInputs[26] = false
    else
        acCarPhysics.controllerInputs[26] = resetBrakeWearAtTyreChange
    end

    acCarPhysics.controllerInputs[27] = carHasTeleportedToPits

    acCarPhysics.controllerInputs[28] = thisCar.fuelMap
    printDebug("Fuelmap", "" .. thisCar.fuelMap)
    acCarPhysics.controllerInputs[29] = radiatorSetup
    acCarPhysics.controllerInputs[30] = turboEnabled
    acCarPhysics.controllerInputs[31] = getDistanceToClosestTyreStack()
    printDebug("Distance to closest tyre stack", acCarPhysics.controllerInputs[31])
    acCarPhysics.controllerInputs[32] = getOverrevvingState()
    printDebug("OverrevvingState", acCarPhysics.controllerInputs[32])
    acCarPhysics.controllerInputs[33] = fuelLeakageDamage
    acCarPhysics.controllerInputs[34] = fuelExhaustionAmount

    acCarPhysics.controllerInputs[35] = sparkPlugFailureRate
    acCarPhysics.controllerInputs[36] = fuelPumpFailureRate
    acCarPhysics.controllerInputs[37] = oilPressureFailureRate
    acCarPhysics.controllerInputs[38] = valveFailureRate
    acCarPhysics.controllerInputs[39] = brakeFadeStart
    acCarPhysics.controllerInputs[40] = brakeWearLevel

    acCarPhysics.controllerInputs[41] = getLowRpmState()

    -- 0 = nothing's happening, 1 = fetching tyre, 2 = changing tyre, 3 = tyre change done
    acCarPhysics.controllerInputs[42] = roadsideTyreChange
    -- 43 - 48: electrical system outputs; 49 - 50: Wilson preselector outputs.
    acCarPhysics.controllerInputs[51] = ignitionType
    -- 52: alternator belt repair; 53 - 62: oil system; 63 - 68: fuel pressure.
    acCarPhysics.controllerInputs[69] = getFouledSparkPlugCount()
    acCarPhysics.controllerInputs[70] = getDeadSparkCylinderCount()
    acCarPhysics.controllerInputs[71] = getSparkPlugPowerLossFraction()
    acCarPhysics.controllerInputs[72] = sparkPlugRepairInProgress or sparkPlugRoadsideRepairInProgress
    acCarPhysics.controllerInputs[73] = coolingSystemType
    -- 74 - 79: air-cooling fault and repair outputs.
    -- 80: crash fire active; 81: intensity; 82: time remaining fraction.
    -- 83: animationsState helper; only for PSG for now
end
-- MAIN UPDATE ENDS
