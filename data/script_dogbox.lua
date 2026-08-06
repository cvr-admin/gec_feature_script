-- Dog-ring gearbox simulation for 1970s/1980s racing H-pattern cars.

require "script_car_parameters"

local dogboxPhysics = ac.accessCarPhysics()
local dogboxState = {
    forcedGearIndex = 1,
    requestedShiftTimer = 0,
    messageCooldown = 0,
    grindDamageTimer = 0,
    grindingApplied = false,
    wasEnabled = false,
    preloadStartGas = nil,
    preloadRequestedGearIndex = nil,
    clutchMessageRequestedGearIndex = nil,
    engagedForwardGearIndex = 1,
    blockedShiftReason = nil,
    rejectedUpshiftGearIndex = nil,
    rejectedDownshiftGearIndex = nil,
    preShiftPeakGas = 0,
    preShiftPeakTimer = 0,
    neutralLatched = false,
}

local dogboxGearDamage = {}

local function dogboxFeatureEnabled()
    if not isDogboxGearboxEnabled() then
        return false
    end

    if ac.getPatchVersionCode() < dogboxMinimumPatchVersionCode then
        return false
    end

    if dogboxRequiresHShifter and not ac.getSim().controlsWithShifter then
        return false
    end

    if thisCar.isAIControlled then
        return false
    end

    return true
end

local function isValidDogboxGearRequest(requestedGearIndex)
    return requestedGearIndex >= 1 and requestedGearIndex <= thisCar.gearCount + 1
end

local function clearDogboxGrinding()
    if dogboxState.grindingApplied and dogboxState.grindDamageTimer <= 0 then
        ac.setGearsGrinding(false, 0)
        dogboxState.grindingApplied = false
    end
end

local function queueDogboxMessage(message)
    if dogboxState.messageCooldown <= 0 and overheadMessageQueue then
        overheadMessageQueue("DOGBOX", message, 2)
        dogboxState.messageCooldown = dogboxBlockedShiftMessageCooldown
    end
end

local function applyBlockedShiftFeedback()
    if dogboxEnableBlockedShiftGrinding then
        ac.setGearsGrinding(true, dogboxBlockedShiftGrindDamageK)
        dogboxState.grindingApplied = true
    end
end

local function applyMisshiftGearGrinding()
    if dogboxEnableBlockedShiftGrinding then
        ac.setGearsGrinding(true, dogboxMisshiftGrindDamageK)
        dogboxState.grindingApplied = true
        dogboxState.grindDamageTimer = dogboxMisshiftGrindTime
    end
end

local function getDogboxPhysicalGearIndex(requestedGearIndex, currentGearIndex)
    local gearIndex = (requestedGearIndex or currentGearIndex or 1) - 1
    if gearIndex < 1 then
        gearIndex = (currentGearIndex or 1) - 1
    end

    if gearIndex >= 1 and gearIndex <= thisCar.gearCount then
        return gearIndex
    end

    return nil
end

local function applyDogboxMisshiftGearDamage(requestedGearIndex, currentGearIndex, reason)
    local gearIndex = getDogboxPhysicalGearIndex(requestedGearIndex, currentGearIndex)
    if not gearIndex or not deadGears or deadGears[gearIndex] then
        return
    end

    dogboxGearDamage[gearIndex] = (dogboxGearDamage[gearIndex] or 0) + dogboxMisshiftGearDamage
    logDebug("<DOGBOX>Misshift gear damage, gear: ", gearIndex, ", damage: ", dogboxGearDamage[gearIndex], ", reason: ", reason or "unknown", true)

    if dogboxGearDamage[gearIndex] >= dogboxGearFailureDamage then
        deadGears[gearIndex] = true
        overheadMessageQueue("DOGBOX FAILURE", "Gear " .. gearIndex .. " has failed from shift abuse", 5)
        logDebug("<DOGBOX>Gear failed, gear: ", gearIndex, ", reason: ", reason or "unknown", true)
    end
end

function resetDogboxGearbox()
    dogboxState.forcedGearIndex = dogboxPhysics.gear
    dogboxState.engagedForwardGearIndex = dogboxPhysics.gear
    dogboxState.requestedShiftTimer = 0
    dogboxState.messageCooldown = 0
    dogboxState.grindDamageTimer = 0
    dogboxState.preloadStartGas = nil
    dogboxState.preloadRequestedGearIndex = nil
    dogboxState.clutchMessageRequestedGearIndex = nil
    dogboxState.blockedShiftReason = nil
    dogboxState.rejectedUpshiftGearIndex = nil
    dogboxState.rejectedDownshiftGearIndex = nil
    dogboxState.preShiftPeakGas = 0
    dogboxState.preShiftPeakTimer = 0
    dogboxState.neutralLatched = false
    dogboxGearDamage = {}
    dogboxState.wasEnabled = false
    clearDogboxGrinding()
end

function resetDogboxGearDamage()
    dogboxGearDamage = {}
end

function updateDogboxGearbox(dt)
    if dogboxState.messageCooldown > 0 then
        dogboxState.messageCooldown = dogboxState.messageCooldown - dt
    end

    if dogboxState.grindDamageTimer > 0 then
        dogboxState.grindDamageTimer = math.max(0, dogboxState.grindDamageTimer - dt)
        clearDogboxGrinding()
    end

    if not dogboxFeatureEnabled() or isCarInPits then
        if dogboxState.wasEnabled then
            resetDogboxGearbox()
        end
        return
    end

    dogboxState.wasEnabled = true

    if dogboxDisableOriginalDrivetrainDamageRpmWindow then
        ac.setDrivetrainDamageRPMWindow(0)
    end

    local currentGearIndex = dogboxState.engagedForwardGearIndex
    if currentGearIndex <= 1 or not isValidDogboxGearRequest(currentGearIndex) then
        currentGearIndex = dogboxState.forcedGearIndex
    end
    if currentGearIndex <= 1 or not isValidDogboxGearRequest(currentGearIndex) then
        currentGearIndex = dogboxPhysics.gear
    end
    if currentGearIndex > 1 and isValidDogboxGearRequest(currentGearIndex) then
        dogboxState.engagedForwardGearIndex = currentGearIndex
        dogboxState.forcedGearIndex = currentGearIndex
    end
    local requestedGearIndex = dogboxPhysics.requestedGearIndex
    if requestedGearIndex <= 0 then
        dogboxState.requestedShiftTimer = 0
        dogboxState.preloadStartGas = nil
        dogboxState.preloadRequestedGearIndex = nil
        dogboxState.clutchMessageRequestedGearIndex = nil
        dogboxState.blockedShiftReason = nil
        dogboxState.rejectedUpshiftGearIndex = nil
        dogboxState.rejectedDownshiftGearIndex = nil
        dogboxState.forcedGearIndex = 0
        dogboxState.engagedForwardGearIndex = 1
        dogboxState.neutralLatched = false
        dogboxPhysics.requestedGearIndex = 0
        ac.overrideSpecificValue(ac.CarPhysicsValueID.DrivetrainEngagedGear, 0)
        clearDogboxGrinding()
        return
    end

    local driverIsRequestingDifferentGear = requestedGearIndex ~= currentGearIndex
    local driverIsRequestingUpshift = currentGearIndex > 1 and requestedGearIndex > currentGearIndex
    local driverGas = math.max(acCarPhysics.gas or 0, dogboxPhysics.gas or 0, thisCar.gas or 0)
    local driverClutch = thisCar.clutch
    local upshiftUsesClutch = driverClutch ~= nil and driverClutch < dogboxUpshiftClutchMessageThreshold
    local downshiftUsesClutch = driverClutch ~= nil and driverClutch < dogboxDownshiftClutchThreshold

    -- Neutral is an intentional, stable position. Keep it selected until the
    -- driver makes a new clutch-assisted gear selection, rather than allowing
    -- AC drivetrain state or throttle input to restore the previous gear.
    if requestedGearIndex == 1 then
        dogboxState.forcedGearIndex = 1
        dogboxState.neutralLatched = true
        dogboxState.requestedShiftTimer = 0
        dogboxState.preloadStartGas = nil
        dogboxState.preloadRequestedGearIndex = nil
        dogboxState.clutchMessageRequestedGearIndex = nil
        dogboxState.blockedShiftReason = nil
        dogboxState.rejectedUpshiftGearIndex = nil
        dogboxState.rejectedDownshiftGearIndex = nil
        dogboxPhysics.requestedGearIndex = 1
        ac.overrideSpecificValue(ac.CarPhysicsValueID.DrivetrainEngagedGear, 1)
        clearDogboxGrinding()
        return
    end

    if dogboxState.neutralLatched and requestedGearIndex > 1 then
        if not downshiftUsesClutch then
            dogboxState.forcedGearIndex = 1
            dogboxPhysics.requestedGearIndex = 1
            ac.overrideSpecificValue(ac.CarPhysicsValueID.DrivetrainEngagedGear, 1)
            queueDogboxMessage("Use clutch to engage from neutral")
            return
        end
        dogboxState.neutralLatched = false
    end

    if not driverIsRequestingDifferentGear then
        dogboxState.preShiftPeakTimer = math.max(0, dogboxState.preShiftPeakTimer - dt)
        if driverGas >= (dogboxState.preShiftPeakGas or 0) or dogboxState.preShiftPeakTimer <= 0 then
            dogboxState.preShiftPeakGas = driverGas
            dogboxState.preShiftPeakTimer = dogboxUpshiftPreloadLookbackSeconds
        end
    elseif dogboxState.preShiftPeakTimer > 0 then
        dogboxState.preShiftPeakTimer = math.max(0, dogboxState.preShiftPeakTimer - dt)
    else
        dogboxState.preShiftPeakGas = driverGas
        dogboxState.preShiftPeakTimer = dogboxUpshiftPreloadLookbackSeconds
    end

    if requestedGearIndex == 1 then
        dogboxState.rejectedUpshiftGearIndex = nil
        dogboxState.rejectedDownshiftGearIndex = nil
    elseif dogboxState.rejectedUpshiftGearIndex == requestedGearIndex then
        dogboxPhysics.requestedGearIndex = 1
        dogboxState.forcedGearIndex = 1
        ac.overrideSpecificValue(ac.CarPhysicsValueID.DrivetrainEngagedGear, dogboxState.forcedGearIndex)
        return
    elseif downshiftUsesClutch then
        dogboxState.rejectedDownshiftGearIndex = nil
    elseif dogboxState.rejectedDownshiftGearIndex == requestedGearIndex then
        dogboxPhysics.requestedGearIndex = 1
        dogboxState.forcedGearIndex = 1
        ac.overrideSpecificValue(ac.CarPhysicsValueID.DrivetrainEngagedGear, dogboxState.forcedGearIndex)
        return
    end

    local downshiftWithoutClutch = driverIsRequestingDifferentGear
            and requestedGearIndex > 1
            and requestedGearIndex < currentGearIndex
            and not downshiftUsesClutch
    local upshiftLiftedEnough = driverGas <= dogboxUpshiftCoastGasThreshold
    local drivetrainLoadNm = math.abs((thisCar.drivetrainTorque or 0) * (dogboxPhysics.clutch or 0))
    local drivetrainIsLoaded = drivetrainLoadNm > dogboxTorqueLockThresholdNm
    local upshiftStillLoaded = false
    local shiftBlockedByLoad = false

    if driverIsRequestingDifferentGear and driverIsRequestingUpshift then
        if upshiftUsesClutch and dogboxState.clutchMessageRequestedGearIndex ~= requestedGearIndex then
            queueDogboxMessage("Do not clutch dogbox upshifts")
            applyMisshiftGearGrinding()
            applyDogboxMisshiftGearDamage(requestedGearIndex, currentGearIndex, "clutched upshift")
            dogboxState.clutchMessageRequestedGearIndex = requestedGearIndex
        end

        if dogboxState.preloadRequestedGearIndex ~= requestedGearIndex then
            dogboxState.preloadStartGas = math.max(driverGas, dogboxState.preShiftPeakGas or 0)
            dogboxState.preloadRequestedGearIndex = requestedGearIndex
        end

        if dogboxState.preloadStartGas then
            upshiftLiftedEnough = upshiftLiftedEnough
                    or dogboxState.preloadStartGas - driverGas >= dogboxUpshiftLiftDropThreshold
        end

        upshiftStillLoaded = not upshiftLiftedEnough
    end

    shiftBlockedByLoad = upshiftStillLoaded
            or downshiftWithoutClutch
            or (drivetrainIsLoaded and not driverIsRequestingUpshift)

    if shiftBlockedByLoad then
        if driverIsRequestingDifferentGear then
            dogboxState.requestedShiftTimer = dogboxState.requestedShiftTimer + dt
            if downshiftWithoutClutch then
                dogboxState.blockedShiftReason = "Use clutch for dogbox downshifts"
            elseif upshiftStillLoaded then
                dogboxState.blockedShiftReason = "Shift preload missed"
            else
                dogboxState.blockedShiftReason = "Shift preload missed"
            end
            applyBlockedShiftFeedback()
        else
            clearDogboxGrinding()
            dogboxState.requestedShiftTimer = 0
            dogboxState.blockedShiftReason = nil
        end

        if currentGearIndex ~= 1 then
            dogboxPhysics.requestedGearIndex = currentGearIndex
            dogboxState.forcedGearIndex = currentGearIndex
        end
    else
        clearDogboxGrinding()

        if driverIsRequestingDifferentGear and isValidDogboxGearRequest(requestedGearIndex) then
            dogboxState.forcedGearIndex = requestedGearIndex
            if requestedGearIndex > 1 then
                dogboxState.engagedForwardGearIndex = requestedGearIndex
            end
        end

        dogboxState.requestedShiftTimer = 0
        dogboxState.preloadStartGas = nil
        dogboxState.preloadRequestedGearIndex = nil
        dogboxState.clutchMessageRequestedGearIndex = nil
        dogboxState.blockedShiftReason = nil
        dogboxState.rejectedUpshiftGearIndex = nil
        dogboxState.rejectedDownshiftGearIndex = nil
        dogboxState.preShiftPeakGas = driverGas
        dogboxState.preShiftPeakTimer = dogboxUpshiftPreloadLookbackSeconds
    end

    if dogboxStrictPreloadWindow and dogboxState.requestedShiftTimer > dogboxPreloadTimeoutSeconds then
        if upshiftStillLoaded then
            dogboxState.rejectedUpshiftGearIndex = requestedGearIndex
        end
        if downshiftWithoutClutch then
            dogboxState.rejectedDownshiftGearIndex = requestedGearIndex
        end
        dogboxPhysics.requestedGearIndex = 1
        dogboxState.forcedGearIndex = 1
        dogboxState.engagedForwardGearIndex = 1
        dogboxState.requestedShiftTimer = 0
        dogboxState.preloadStartGas = nil
        dogboxState.preloadRequestedGearIndex = nil
        dogboxState.clutchMessageRequestedGearIndex = nil
        applyMisshiftGearGrinding()
        applyDogboxMisshiftGearDamage(requestedGearIndex, currentGearIndex, dogboxState.blockedShiftReason)
        queueDogboxMessage(dogboxState.blockedShiftReason or "Shift preload missed")
        dogboxState.blockedShiftReason = nil
    end

    ac.overrideSpecificValue(ac.CarPhysicsValueID.DrivetrainEngagedGear, dogboxState.forcedGearIndex)
end

resetDogboxGearbox()
