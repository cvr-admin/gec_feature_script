-- Tyre system: punctures, wear, roadside replacement, and crash-blow detection.

require "script_car_parameters"

-- Shared state (globals)
tyrePressures = {} --store the original tyre pressures here (do it when exiting pits)
tyrevKMs = {} --store the tyre vKMs here
tyreWear = {}
prevTyreWear = {}
tyrePunctureRates = {}
isCarInPits = false
currentSpares = 2 -- get this when exiting pits
tyreChangeInProgress = false --is the car changing a tyre
pitCrewTyreChangeInProgress = false
roadsideTyreChange = 0
tyreStockEmpty = false
carStoppedTimer = 0 --the timer to check if car is stopped for a tyre replacement
tyrePunctureTestIndex = -1 -- used by test code

-- Module-local tyre state
local prevDamageFront = thisCar.damage[0]
local prevDamageRear = thisCar.damage[1]
local prevDamageLeft = thisCar.damage[2]
local prevDamageRight = thisCar.damage[3]

-- Tyre stack placement (roadside spare service)
local maxDistanceBetweenTyreStacks = 1000
local tyreStacksPerLap = math.max(math.ceil(ac.getSim().trackLengthM / maxDistanceBetweenTyreStacks) - 1, 2)
local tyreStacksPositions = {}

local pitStopTyreChangeTime = ac.INIConfig.carData(0, 'car.ini'):get('PIT_STOP', 'TYRE_CHANGE_TIME_SEC', 55)
local tyreReplacementTime = pitStopTyreChangeTime / 4
local roadsideTyreReplacementTime = tyreReplacementTime * 1.6

local function resetTyreVirtualKM(tyreIndex, virtualKm)
    virtualKm = virtualKm or 0
    if physics and physics.setTyresVirtualKM then
        local wheelMask = 2 ^ (tyreIndex + 2)
        return pcall(physics.setTyresVirtualKM, 0, wheelMask, virtualKm)
    end
    if ac.overrideSpecificValue and ac.CarPhysicsValueID and ac.CarPhysicsValueID.TyresVirtualKm then
        return pcall(ac.overrideSpecificValue, ac.CarPhysicsValueID.TyresVirtualKm, virtualKm, tyreIndex)
    end
    return false
end

local cvrPitCrewConnection = nil
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
        cvrPitCrewConnection = connection
    end
end
local cvrPitCrewLastRequestId = 0
local cvrPitCrewPendingRequestId = 0
local cvrPitCrewPendingMask = 0
local cvrPitCrewTimer = 0
local cvrPitCrewDuration = 0
local pitCrewTyreServiceCooldown = 0
local cvrPitCrewRoadsideTyreService = false
local cvrPitCrewRoadsideTyreServiceCooldown = 0
local tyrePatchTemperatureResetMask = 0
local tyrePatchTemperatureResetFrames = 0
local tyrePatchTemperatureResetFrameCount = 180

local function tyreMaskHasWheel(mask, tyreIndex)
    return math.floor((mask or 0) / (2 ^ tyreIndex)) % 2 == 1
end

local function countTyresInMask(mask)
    local count = 0
    for i = 0, 3 do
        if tyreMaskHasWheel(mask, i) then
            count = count + 1
        end
    end
    return count
end

local function getPitCrewTyreChangeTime(mask)
    return tyreReplacementTime * countTyresInMask(mask)
end

function getCVRPitCrewTyreChangeTime(mask)
    return getPitCrewTyreChangeTime(mask)
end

local function queueTyrePatchTemperatureReset(mask)
    tyrePatchTemperatureResetMask = mask
    tyrePatchTemperatureResetFrames = tyrePatchTemperatureResetFrameCount
end

local function resetTyrePatchTemperatures(tyreIndex)
    if ac.shiftPatchTemperatures then
        return pcall(ac.shiftPatchTemperatures, tyreIndex, 25, 1)
    end
    return false
end

function resetTyreWearTracking(tyreIndex)
    tyreWear[tyreIndex] = 0.0
    prevTyreWear[tyreIndex] = thisCar.wheels[tyreIndex].tyreWear or 0.0
end

-- Keep the pit crew and roadside tyre workflows separate. This is also called
-- for session resets because controller outputs can outlive an AC restart.
function resetTyreServiceState()
    tyreChangeInProgress = false
    pitCrewTyreChangeInProgress = false
    roadsideTyreChange = 0
    carStoppedTimer = 0
    blownTyres = false
    pitCrewTyreServiceCooldown = 0
    cvrPitCrewPendingRequestId = 0
    cvrPitCrewPendingMask = 0
    cvrPitCrewTimer = 0
    cvrPitCrewDuration = 0
    cvrPitCrewRoadsideTyreService = false
    cvrPitCrewRoadsideTyreServiceCooldown = 0
    tyrePatchTemperatureResetMask = 0
    tyrePatchTemperatureResetFrames = 0

    if cvrPitCrewConnection then
        cvrPitCrewConnection.tyreMask = 0
        cvrPitCrewConnection.status = 0
    end
    if acCarPhysics and acCarPhysics.controllerInputs then
        acCarPhysics.controllerInputs[3] = 0
        acCarPhysics.controllerInputs[42] = 0
    end
end

function updateCVRPitCrewTyreOverrides()
    if tyrePatchTemperatureResetFrames <= 0 or tyrePatchTemperatureResetMask == 0 then
        return
    end

    for i = 0, 3 do
        if tyreMaskHasWheel(tyrePatchTemperatureResetMask, i) then
            resetTyrePatchTemperatures(i)
        end
    end

    tyrePatchTemperatureResetFrames = tyrePatchTemperatureResetFrames - 1
    if tyrePatchTemperatureResetFrames <= 0 then
        tyrePatchTemperatureResetMask = 0
    end
end

local function servicePitCrewTyre(tyreIndex)
    ac.setTyreInflation(tyreIndex, tyrePressures[tyreIndex] or 1.0)
    resetTyreVirtualKM(tyreIndex)
    resetTyrePatchTemperatures(tyreIndex)

    tyrevKMs[tyreIndex] = generateTyrevKM()
    tyrePunctureDeflateFactor[tyreIndex] = 0.0
    tyrePuncturePressureFactor[tyreIndex] = 0.0
    resetTyreWearTracking(tyreIndex)
end

local function holdCarForPitCrewTyreChange()
    pitCrewTyreChangeInProgress = true
    acCarPhysics.gas = 0
    acCarPhysics.brake = 1
    acCarPhysics.handbrake = 1

    if forceEngineStall then
        forceEngineStall()
    else
        ac.setEngineRPM(0)
    end
end

function isCVRPitCrewTyreServiceActive()
    return pitCrewTyreChangeInProgress or cvrPitCrewPendingRequestId ~= 0
end

function applyCVRPitCrewTyreSelection(dt)
    if not cvrPitCrewConnection then
        pitCrewTyreChangeInProgress = false
        return
    end

    local requestId = tonumber(cvrPitCrewConnection.requestId) or 0
    local tyreMask = tonumber(cvrPitCrewConnection.tyreMask) or 0
    if requestId == 0 or requestId == cvrPitCrewLastRequestId or tyreMask == 0 then
        pitCrewTyreChangeInProgress = false
        return
    end

    if not isCarInPits then
        local pitCrewServiceWasActive = pitCrewTyreChangeInProgress or cvrPitCrewPendingRequestId ~= 0
        if cvrPitCrewPendingRequestId ~= 0 then
            cvrPitCrewConnection.status = 0
        end
        pitCrewTyreChangeInProgress = false
        cvrPitCrewPendingRequestId = 0
        cvrPitCrewPendingMask = 0
        cvrPitCrewTimer = 0
        cvrPitCrewDuration = 0
        if pitCrewServiceWasActive then
            pitCrewTyreServiceCooldown = math.max(pitCrewTyreServiceCooldown, 0.25)
        end
        return
    end

    -- Some cars need the tyre crew and mechanical repair crew to work in
    -- sequence. Keep the accepted tyre request pending until the repair queue
    -- is clear, then run the normal tyre service.
    if pitTyreChangesCanRunWithRepairs == false
            and isCustomPitRepairQueueActive and isCustomPitRepairQueueActive() then
        pitCrewTyreChangeInProgress = false
        cvrPitCrewConnection.status = 3
        return
    end

    if requestId ~= cvrPitCrewPendingRequestId or tyreMask ~= cvrPitCrewPendingMask then
        cvrPitCrewPendingRequestId = requestId
        cvrPitCrewPendingMask = tyreMask
        cvrPitCrewTimer = 0
        cvrPitCrewDuration = getPitCrewTyreChangeTime(tyreMask)
        cvrPitCrewConnection.status = 3
        overheadMessageQueue("Pit crew", string.format("Changing selected tyres: %.0f s", cvrPitCrewDuration), 3)
    end

    holdCarForPitCrewTyreChange()
    cvrPitCrewTimer = cvrPitCrewTimer + (dt or 0)
    printDebug("CVR Pit crew time", string.format("%.1f / %.1f", cvrPitCrewTimer, cvrPitCrewDuration))
    if cvrPitCrewTimer < cvrPitCrewDuration then
        cvrPitCrewConnection.status = 3
        return
    end

    cvrPitCrewLastRequestId = requestId
    local appliedMask = 0
    for i = 0, 3 do
        if tyreMaskHasWheel(tyreMask, i) then
            servicePitCrewTyre(i)
            appliedMask = appliedMask + 2 ^ i
        end
    end

    cvrPitCrewConnection.appliedRequestId = requestId
    cvrPitCrewConnection.appliedMask = appliedMask
    cvrPitCrewConnection.status = appliedMask > 0 and 1 or 2
    cvrPitCrewConnection.carIndex = thisCar.index or 0
    cvrPitCrewConnection.tyreMask = 0
    cvrPitCrewPendingRequestId = 0
    cvrPitCrewPendingMask = 0
    cvrPitCrewTimer = 0
    cvrPitCrewDuration = 0
    pitCrewTyreChangeInProgress = false
    pitCrewTyreServiceCooldown = 0.25

    if appliedMask > 0 then
        queueTyrePatchTemperatureReset(appliedMask)
        overheadMessageQueue("Pit crew", "Selected tyres changed.", 3)
        printDebug("CVR Pit crew", string.format("Applied mask %d", appliedMask))
    end
end

function initTyrePunctureRates()
    for i = 0, 3 do
        tyrePunctureRates[i] = 0.0
    end
end

function initTyrePunctureTables()
    for i = 0, 3 do
        tyrePunctureDeflateFactor[i] = 0.0
        tyrePuncturePressureFactor[i] = 0.0
    end
end

function initTyreWearTable()
    for i = 0, 3 do
        tyreWear[i] = 0.0
        prevTyreWear[i] = 0.0
    end
end

local function initTyreStacksPositions()
    local trackLength = ac.getSim().trackLengthM
    for i = 0, tyreStacksPerLap - 1 do
        local position = (i * trackLength) / tyreStacksPerLap
        table.insert(tyreStacksPositions, position)
    end

    -- Insert the track length at the end to complete the loop.
    table.insert(tyreStacksPositions, trackLength)

    printDebug("tyreStacksPositions", tyreStacksPositions)
    printDebug("Tyre stack count", tyreStacksPerLap)
end

function getDistanceToClosestTyreStack()
    local carPositionOnTrack = thisCar.splinePosition * ac.getSim().trackLengthM
    -- Find the distance to the closest tyre stack.
    local closestTyreStackDistance = math.huge
    for i = 1, #tyreStacksPositions do
        local stackPosition = tyreStacksPositions[i]
        local distance = math.abs(stackPosition - carPositionOnTrack)
        if distance < closestTyreStackDistance then
            closestTyreStackDistance = distance
        end
    end

    return closestTyreStackDistance
end

-- Get tyre change time. If we're doing a roadside tyre change, calculate the time based on
-- the distance to the closest tyre stack.
function getTyreChangeTime()
    if currentSpares >= 0 then
        return roadsideTyreReplacementTime
    end

    local jeffRunSpeedMs = 4.0
    local timeToTyreStackAndBack = getDistanceToClosestTyreStack() / jeffRunSpeedMs * 2
    printDebug("Time to tyre stack and back", timeToTyreStackAndBack)

    return roadsideTyreReplacementTime + timeToTyreStackAndBack
end

function getCurrentSpares()
    local spares = ac.getScriptSetupValue("SPARE_WHEELS")()
    printDebug("Current spares", spares)
        if spares == "Trackside" then
            spares = -1
        end

    return spares
end

local function debugTyrevKMs()
    for i = 0, 3 do
        printDebug("tyrevKM_" .. i, tyrevKMs[i])
    end
end

function getWheelName(tyreIndex)
    wheelNames = {"Front left", "Front right", "Rear left", "Rear right"}
    return wheelNames[tyreIndex + 1]
end

function generateSlowPuncture(tyreIndex, minFactor, maxFactor)
    -- Generate a factor to use deflating the tyre, defining the speed of deflation.
    -- This value will be subtracted from the pressure factor 10 times a second.
    tyrePunctureDeflateFactor[tyreIndex] = 1 / math.random(minFactor, maxFactor)
    -- Set the tyre pressure factor to start the deflation from. See ac.setTyreInflation() comment in slowTyrePuncture().
    tyrePuncturePressureFactor[tyreIndex] = 1.0
    overheadMessageQueue("Tyre puncture", getWheelName(tyreIndex) .. " tyre is leaking!", 3)
    printDebug(string.format("Puncture factor, tyre: %d", tyreIndex), string.format("%f", tyrePunctureDeflateFactor[tyreIndex]))
    logDebug("<FLR>Tyre Puncture, tyre: ", tyreIndex, " Deflate factor: ", tyrePunctureDeflateFactor[tyreIndex], true)
end

function getTyreTypeFactor()
    local tyreName = ac.getTyresName(thisCar.index)
    printDebug("tyreName", tyreName)
    local tyreTypeFactor = 1
    for i = 1, #tyreTypeFactors do
        if tyreName == tyreTypeFactors[i][1] then
            tyreTypeFactor = tyreTypeFactors[i][2]
            break
        end
    end

    return tyreTypeFactor
end

--tyre blow function. rest of tyre stuff in other functions
function tyreBlow()
    local checkTyreBlow = not isCarInPits and thisCar.speedKmh > 1
    local tyreTypeFactor = getTyreTypeFactor()
    printDebug("tyreTypeFactor", tyreTypeFactor)

    for i = 0, 3 do
        -- Car must be out of the pits and not in the grid, moving and tyre must not be already punctured.
        if checkTyreBlow and tyrePunctureDeflateFactor[i] == 0.0 then
            local rateToUse = 0

            if thisCar.wheels[i].surfaceExtendedType == ac.SurfaceExtendedType.Gravel then
                rateToUse = tyrePunctureRateGravel
                ac.setTyreWearMultiplier(i, tyreWearGravel)
                trackSurfaceType = ac.SurfaceExtendedType.Gravel
            elseif thisCar.wheels[i].surfaceExtendedType == ac.SurfaceExtendedType.Ice or
                   thisCar.wheels[i].surfaceExtendedType == ac.SurfaceExtendedType.Snow then
                rateToUse = tyrePunctureRateIce
                ac.setTyreWearMultiplier(i, tyreWearIce)
                trackSurfaceType = ac.SurfaceExtendedType.Ice
            else
                rateToUse = tyrePunctureRateAsphalt
                ac.setTyreWearMultiplier(i, tyreWearAsphalt)
                trackSurfaceType = ac.SurfaceExtendedType.Base
            end

            -- Modify rateFactor so that more worn tyres are more likely to puncture. The tyreWear table
            -- contains the accumulated wear since the start of the session, 0 meaning brand new tyres and
            -- 1 meaning fully worn tyres.
            local tyreWearFactor = 1.0 - math.min(tyreWear[i] * tyreTypeFactor, 0.999)
            rateToUse = math.floor(rateToUse * tyreWearFactor + 0.5)
            printDebug(string.format("Puncture rate, tyre: %d", i), string.format("%d", rateToUse))
            tyrePunctureRates[i] = rateToUse

            local tyrePunctureTesting = false
            if TEST_CODE and tyrePunctureTestIndex == i then
                tyrePunctureTesting = true
            end
            if math.random(1, rateToUse) == 1 or tyrePunctureTesting then
                generateSlowPuncture(i, minPunctureDeflateFactor, maxPunctureDeflateFactor)
            end
        end

        --check tyre pressure for each wheel and set to blow if it's too high
        if thisCar.wheels[i].tyrePressure > tyreBlowPressure and thisCar.wheels[i].isBlown == false and tyrePunctureDeflateFactor[i] == 0.0 then
            -- In this case, make sure the tyre always deflates quickly.
            generateSlowPuncture(i, minPunctureDeflateFactor, minPunctureDeflateFactor)

            if currentSpares > 0 then
                overheadMessageQueue("Spares available", "You have " .. currentSpares .. " spares left, pull over to the side when safe.", 2)
            else
                overheadMessageQueue("No spares", "You have no spares left, just get to the pits safely!", 2)
            end
        end
        --check tyrevKM and blow it if its past its life
        if thisCar.wheels[i].tyreVirtualKM > tyrevKMs[i] and thisCar.wheels[i].isBlown == false and tyrePunctureDeflateFactor[i] == 0.0 then
            generateSlowPuncture(i, minPunctureDeflateFactor, maxPunctureDeflateFactor)

            if currentSpares > 0 then
                overheadMessageQueue("Spares available", "You have " .. currentSpares .. " spares left, pull over to the side when safe.", 2)
            else
                overheadMessageQueue("No spares", "You have no spares left, just get to the pits safely!", 2)
            end
        end
    end
end--end of tyre blow function

-- Slow tyre puncture: deflate the tyre over time.
function slowTyrePuncture()
    for i = 0, 3 do
        -- If the tyre is punctured, we need to deflate it.
        if tyrePunctureDeflateFactor[i] > 0.0 then
            -- Calculate new (deflated) pressure factor and set it to the tyre.
            tyrePuncturePressureFactor[i] = tyrePuncturePressureFactor[i] - tyrePunctureDeflateFactor[i]
            -- Limit the pressure factor to 0, to blow the tyre.
            if tyrePuncturePressureFactor[i] < 0 then
                tyrePuncturePressureFactor[i] = 0
            end
            -- Set the deflated tyre pressure. setTyreInflation() takes a "percentage" as a parameter,
            -- from 0 to 1. 1 sets the full original pressure, and e.g. 0,5 sets half of that. For
            -- example, if the original pressure value was 50 psi, setting 0,5 here would set the pressure
            -- to 25 psi. When the factor reaches zero, the tyre will be blown.
            ac.setTyreInflation(i, tyrePuncturePressureFactor[i])

            printDebug(string.format("Set tyre: %d", i), string.format("deflated pressure: %f", tyrePuncturePressureFactor[i]))
        end
    end
end

function isAnyTyrePunctured()
    for i = 0, 3 do
        if tyrePunctureDeflateFactor[i] > 0.0 then
            return true
        end
    end
    return false
end

function updateTyreWear()
    for i = 0, 3 do
        local currentWear = thisCar.wheels[i].tyreWear or 0.0
        local previousWear = prevTyreWear[i]

        -- CSP can reset raw wear after the pit service completes. Rebase the
        -- tracker instead of counting a previous tyre's wear a second time.
        if previousWear == nil or currentWear < previousWear then
            prevTyreWear[i] = currentWear
        elseif currentWear > previousWear then
            local wearDiff = currentWear - previousWear
            tyreWear[i] = tyreWear[i] + wearDiff
            prevTyreWear[i] = currentWear
            printDebug(string.format("tyreWear " .. i), tyreWear[i])
        end
    end
end

--helper function for generating a fresh tyre.
function generateTyrevKM()
    local randomFactor = math.random() -- Uniform random value between 0 and 1
    -- Apply weighting toward the upper end of the range
    local weightedLife = tyreBasevKM + (tyrevKMvariance * (randomFactor ^ biasStrength))
    return weightedLife
end

local function blowTyreAtCrash(damageDiff, sideDamage1, sideDamage2, tyre1, tyre2)
    local tyreToBlow = 0
    local rate = tyreBlowCrashingRate

    -- In a really hard crash, just blow both tyres.
    if damageDiff > tyreBlowDamageChangeMax then
        ac.setTyreInflation(tyre1, 0)
        ac.setTyreInflation(tyre2, 0)
        return
    end

    -- Check if there is enough change in damage to blow a tyre.
    if damageDiff > tyreBlowDamageChange then
        -- Is the damage hard enough to blow the tyre using 100% probability?
        if damageDiff > tyreBlowDamageChangeHard then
            rate = 1
        end

        -- Blow the tyre from that side, which has more damage.
        -- For example, if this is a front crash, then choose left or right.
        if sideDamage1 > sideDamage2 then
            tyreToBlow = tyre1
        else
            tyreToBlow = tyre2
        end

        if math.random(1, rate) == 1 then
            ac.setTyreInflation(tyreToBlow, 0)
        end
    end
end

-- Blow a tyre when the car is crashed into something. Check the change in
-- car damage, and when it exceeds the predefined value, then blow a tyre.
function tyreBlowWhenCrashing()
    printDebug("-Front dmg", thisCar.damage[0])
    printDebug("-Rear dmg", thisCar.damage[1])
    printDebug("-Left dmg", thisCar.damage[2])
    printDebug("-Right dmg", thisCar.damage[3])

    -- Front crash.
    blowTyreAtCrash(thisCar.damage[0] - prevDamageFront, thisCar.damage[2], thisCar.damage[3], 0, 1)
    -- Rear crash.
    blowTyreAtCrash(thisCar.damage[1] - prevDamageRear, thisCar.damage[2], thisCar.damage[3], 2, 3)
    -- Left crash.
    blowTyreAtCrash(thisCar.damage[2] - prevDamageLeft, thisCar.damage[0], thisCar.damage[1], 0, 2)
    -- Right crash.
    blowTyreAtCrash(thisCar.damage[3] - prevDamageRight, thisCar.damage[0], thisCar.damage[1], 1, 3)

    prevDamageFront = thisCar.damage[0]
    prevDamageRear = thisCar.damage[1]
    prevDamageLeft = thisCar.damage[2]
    prevDamageRight = thisCar.damage[3]
end

--tyre replacement bits - this function is the whole routine
function tyreReplacement(dt)
    local requestedTyreMask = 0
    for tyreIndex = 0, 3 do
        if isCVRPitCrewRoadsideTyreRequested and isCVRPitCrewRoadsideTyreRequested(tyreIndex) then
            requestedTyreMask = requestedTyreMask + 2 ^ tyreIndex
        end
    end
    local appRoadsideRequest = requestedTyreMask > 0
    local speedKmh = thisCar.speedKmh or 0
    local stoppedWithHandbrake = speedKmh < 1 and (thisCar.handbrake or 0) > 0.9
    local stoppedForRoadsideService = stoppedWithHandbrake or (appRoadsideRequest and speedKmh < 1)

    if cvrPitCrewRoadsideTyreServiceCooldown > 0 then
        cvrPitCrewRoadsideTyreServiceCooldown = math.max(0, cvrPitCrewRoadsideTyreServiceCooldown - (dt or 0))
        carStoppedTimer = 0
        roadsideTyreChange = 0
        acCarPhysics.controllerInputs[3] = 0
        return
    end

    if cvrPitCrewRoadsideTyreService and (speedKmh > 2 or isCarInPits) then
        tyreChangeInProgress = false
        roadsideTyreChange = 0
        carStoppedTimer = 0
        cvrPitCrewRoadsideTyreService = false
        cvrPitCrewRoadsideTyreServiceCooldown = 0.25
        if cancelCVRPitCrewRoadsideService then
            cancelCVRPitCrewRoadsideService()
        end
        return
    end

    -- The pit crew holds the handbrake while working. Briefly ignore that
    -- forced input after service so it cannot arm a roadside change.
    if pitCrewTyreChangeInProgress or pitCrewTyreServiceCooldown > 0 then
        carStoppedTimer = 0
        roadsideTyreChange = 0
        acCarPhysics.controllerInputs[3] = 0
        pitCrewTyreServiceCooldown = math.max(0, pitCrewTyreServiceCooldown - (dt or 0))
        return
    end

    -- A roadside service must be one continuous stop. Clearing this state on
    -- handbrake release prevents stale progress and messages from persisting.
    if not tyreChangeInProgress and not stoppedForRoadsideService then
        carStoppedTimer = 0
        roadsideTyreChange = 0
        acCarPhysics.controllerInputs[3] = 0
        return
    end

    -- Do not start a tyre change while another roadside repair owns the car.
    if not isRepairingBelt then
        carStoppedTimer = carStoppedTimer + dt

        --starting the tyre replacement routine
        if carStoppedTimer > tyreReplacementReactionTime and tyreChangeInProgress == false then
            --check that there is actually a burst tyre
            blownTyres = false
            for i = 0, 3 do
                if (thisCar.wheels[i].isBlown or tyrePunctureDeflateFactor[i] > 0.0)
                        and (not appRoadsideRequest or tyreMaskHasWheel(requestedTyreMask, i)) then
                    tyreChangeInProgress = true
                    blownTyres = true
                end
            end
            --check that you have an available spare, if not, cancel routine
            --also reset the timer, no point in checking it every tick if you dont have a spare
            if currentSpares == 0 then
                tyreChangeInProgress = false
                blownTyres = false
                overheadMessageQueue("No spare tyres", "Drive carefully to the pits", 4, true)
            end
            if blownTyres == false then
                carStoppedTimer = 0
            end
        end

        --tyre change routine, seize controls
        if tyreChangeInProgress then
            if appRoadsideRequest and not cvrPitCrewRoadsideTyreService then
                cvrPitCrewRoadsideTyreService = true
                if beginCVRPitCrewRoadsideService then
                    beginCVRPitCrewRoadsideService()
                end
            end
            acCarPhysics.gas = 0
            acCarPhysics.brake = 1
            acCarPhysics.handbrake = 1
            local tyreChangeTime = getTyreChangeTime()
            if carStoppedTimer < tyreChangeTime - roadsideTyreReplacementTime then
                overheadMessageQueue("Tyre service", "Fetching a tyre from the nearest stack...", 1, true)
                roadsideTyreChange = 1
            else
                overheadMessageQueue("Tyre service", "Changing tyre. Hold position until done.", 1, true)
                roadsideTyreChange = 2
            end
            -- Refresh the queued message with override so roadside progress
            -- remains visible without accumulating duplicate notifications.

            --end the routine once the time has passed
            if carStoppedTimer > getTyreChangeTime() then
                overheadMessageQueue("Tyre change complete", "!VAMOS!", 2)
                tyreChangeInProgress = false
                roadsideTyreChange = 3
                currentSpares = math.max(currentSpares - 1, -1)
                if currentSpares > 0 then
                    overheadMessageQueue("Tyre change complete", "You have " .. currentSpares .. " spares left.", 3)
                end
                if currentSpares == 0 then
                    tyreStockEmpty = true
                else
                    tyreStockEmpty = false
                end
                carStoppedTimer = 0
                for i = 0, 3 do
                    if (thisCar.wheels[i].isBlown or tyrePunctureDeflateFactor[i] > 0.0)
                            and (not cvrPitCrewRoadsideTyreService or tyreMaskHasWheel(requestedTyreMask, i)) then
                        ac.setTyreInflation(i, tyrePressures[i])
                        if resetTyreVirtualKM(i) then
                            tyrevKMs[i] = generateTyrevKM()
                        else
                            -- Fallback for older CSP builds where reinflation does not reset tyre vKM.
                            tyrevKMs[i] = thisCar.wheels[i].tyreVirtualKM + generateTyrevKM()
                        end
                        tyrePunctureDeflateFactor[i] = 0.0
                        -- Reset the tyre wear for the replaced tyre.
                        resetTyreWearTracking(i)
                        if cvrPitCrewRoadsideTyreService then
                            cvrPitCrewRoadsideTyreService = false
                            cvrPitCrewRoadsideTyreServiceCooldown = 0.25
                            if completeCVRPitCrewRoadsideTyreService then
                                completeCVRPitCrewRoadsideTyreService(i)
                            end
                        end
                        break;
                    end
                end--find the first tyre and repair it
            end--end of repair routine

        end--end of seizing controls
        acCarPhysics.controllerInputs[3] = carStoppedTimer
    end--end of stop-checking

    if thisCar.speedKmh > 30 then
        roadsideTyreChange = 0
    end

    printDebug("Tyre change state", roadsideTyreChange)
end--end of tyre replacement function

-- Initialise on load
initTyrePunctureRates()
initTyrePunctureTables()
initTyreWearTable()
initTyreStacksPositions()
