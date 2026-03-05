-- script_psg.lua
-- Wilson‑style preselector gearbox logic

local acRef = nil
local carPhys = nil
local msgQueue = nil
local maxGear = 4  -- sensible(?) fallback

--------------------------------------------------------------------
-- Neutral debounce state
--------------------------------------------------------------------
local neutralTimer = neutralTimer or 0
local neutralDelay = 0.4   -- 0.01 = 1 ms debounce for Neutral
local pendingNeutral = false

-- persistent state
psg_engageDelayRaw   = psg_engageDelayRaw   or 0.15
psg_fs_protection = psg_fs_protection   or true   -- 1..on 0..off
psg_fs_pro_delay  = psg_fs_pro_delay   or 0.1   -- seconds off additional delay - standard: 0.1
psg_engageTimer   = psg_engageTimer   or 0
psg_preselected   = psg_preselected   or 1
psg_engaged       = psg_engaged       or 1
psg_lastLever     = psg_lastLever     or 1
psg_lastClutch    = psg_lastClutch    or 1
psg_clutchTrigger = psg_clutchTrigger or 0.2
psg_changed       = psg_changed       or 0

-- calculate final engage delay
psg_engageDelay = psg_engageDelayRaw
if psg_fs_protection then
    psg_engageDelay = psg_engageDelay + psg_fs_pro_delay
end

-- Paddle input state (persistent)
local lastPaddleUp   = false
local lastPaddleDown = false

-- anim configuration
local psg_animation_hold = 0.3     -- seconds to keep the signal high

-- anim state
local psg_animation_timer = 0      -- counts down to zero


local function gearName(idx)
    if idx == 0 then return "Reverse" end
    if idx == 1 then return "Neutral" end
    if idx == 2 then return "1st" end
    if idx == 3 then return "2nd" end
    if idx == 4 then return "3rd" end
    return (idx - 1) .. "th"
end



function initPSG(ac_, overheadMessageQueue_)
    acRef = ac_
    carPhys = acRef.accessCarPhysics()
    msgQueue = overheadMessageQueue_

    --thisCar = ac_.getCar()
    --print("PSG: this car =", thisCar)

    -- 1. Try drivetrain.ini first
    local ini = acRef.INIConfig.carData(0, 'drivetrain.ini')
    local countFromIni = ini:get('GEARS', 'COUNT', 0)

    if countFromIni > 0 then
        maxGear = countFromIni + 1   
        -- print("PSG: Using drivetrain.ini COUNT =", countFromIni, "→ maxGearIndex =", maxGear)
        return
    end

    -- 2. Try car.gearCount
    local car = acRef.getCar()
    if car and car.gearCount then
        maxGear = car.gearCount - 1
        -- print("PSG: Using car.gearCount =", maxGear)
        return
    end

    -- 3. Fallback
    -- print("PSG: Using fallback maxGear =", maxGear)
end



function updatePSG(dt)
    -- Read physics

    local clutchInput = carPhys.clutch

    local speed = carPhys.speedKmh

    -- Speed ramp parameters
    local maxOverrideSpeed = 25.0  -- km/h
    local t = speed / maxOverrideSpeed

    -- Clamp 0..1
    if t < 0 then t = 0 end
    if t > 1 then t = 1 end

    -- Default override clutch value (PSG logic may change this later)
    local overrideClutch = 1.0

    -- Blend between player clutch and override clutch
    local blendedClutch = clutchInput * (1 - t) + overrideClutch * t

    -- Apply blended clutch to the sim
    carPhys.clutch = blendedClutch

    local lever  = carPhys.requestedGearIndex

    if lever < 0 then
        lever = 1        -- force Neutral
    end

    -- Ignore invalid lever inputs
    if lever > maxGear then
        lever = psg_lastLever
    end


    -- Read paddle inputs directly from physics object
    local paddleUp   = carPhys.gearUp
    local paddleDown = carPhys.gearDown



    --------------------------------------------------------------------
    -- 1. HANDLE PRESELECT INPUTS (H‑shifter + paddles)
    --------------------------------------------------------------------

    -- H‑shifter movement
    if lever ~= psg_lastLever then

        if lever == 1 then
            ------------------------------------------------------------
            -- Lever is in Neutral → start debounce timer
            ------------------------------------------------------------
            neutralTimer = neutralDelay
            pendingNeutral = true

        else
            ------------------------------------------------------------
            -- Lever moved to a real gear → cancel Neutral debounce
            ------------------------------------------------------------
            neutralTimer = 0
            pendingNeutral = false

            psg_preselected = lever
            msgQueue("PRESELECT", gearName(psg_preselected), 1)
            psg_changed = 1
        end
    end

    -- Paddle upshift (debounced)
    if paddleUp and not lastPaddleUp then
        neutralTimer = 0
        pendingNeutral = false

        psg_preselected = math.min(psg_preselected + 1, maxGear)
        msgQueue("PRESELECT", gearName(psg_preselected), 1)
        psg_changed = 1
    end

    -- Paddle downshift (debounced)
    if paddleDown and not lastPaddleDown then
        neutralTimer = 0
        pendingNeutral = false

        psg_preselected = math.max(psg_preselected - 1, 0)
        msgQueue("PRESELECT", gearName(psg_preselected), 1)
        psg_changed = 1
    end

    -- Update paddle state for next frame
    lastPaddleUp   = paddleUp
    lastPaddleDown = paddleDown

    --------------------------------------------------------------------
    -- 1b. PROCESS NEUTRAL DEBOUNCE TIMER
    --------------------------------------------------------------------
    if pendingNeutral then
        neutralTimer = neutralTimer - dt

        if neutralTimer <= 0 then
            -- Lever stayed in Neutral long enough → accept it
            psg_preselected = 1
            msgQueue("PRESELECT", "Neutral", 1)
            psg_changed = 1

            pendingNeutral = false
        end
    end


    -- for external animation - so that [50] is 1 long enough that the other script catches it
    --carPhys.controllerInputs[50] = psg_changed       -- shifting animation
    --print("PSG: preselect change" , carPhys.controllerInputs[50])
    --psg_changed = 0

        -- when a new preselect happens, set the timer
    if psg_changed == 1 then
        psg_animation_timer = psg_animation_hold
        psg_changed = 0
    end

    -- count down the timer
    if psg_animation_timer > 0 then
        psg_animation_timer = psg_animation_timer - dt
        carPhys.controllerInputs[50] = 1
    else
        carPhys.controllerInputs[50] = 0
    end



    --------------------------------------------------------------------
    -- 2. BLOCK AC FROM CHANGING GEARS (Wilson preselector behavior)
    --------------------------------------------------------------------
    carPhys.requestedGearIndex = psg_engaged

  --------------------------------------------------------------------
    -- 3. TRIGGER ENGAGEMENT WHEN CLUTCH IS PRESSED
    --------------------------------------------------------------------
    if clutchInput  <= psg_clutchTrigger and psg_lastClutch > psg_clutchTrigger then



        -- moved below: psg_engaged     = psg_preselected
        psg_engageTimer = psg_engageDelay
        -- msgQueue("ENGAGED", gearName(psg_engaged), 1)
    end

 
    --------------------------------------------------------------------
    -- 4. AFTER DELAY, PERFORM THE ACTUAL ENGAGEMENT
    --------------------------------------------------------------------
    if psg_engageTimer > 0 then
        psg_engageTimer = psg_engageTimer - dt


        -- cut gas if protection enabled
        --if (psg_engageTimer > 0) and ((psg_engaged > 1) or (psg_engaged == 0)) then
        if (psg_engageTimer > 0) and psg_fs_protection then
            carPhys.gas = 0.0

            --print("FSP")

            local isUpshift = psg_preselected > psg_engaged

            if isUpshift then
                -- Gear-dependent clutch limits
                local minClutch = 0.2
                local maxClutch = 1.0

                if psg_engaged == 1 then
                    minClutch = 0.15
                    maxClutch = 0.3
                elseif psg_engaged == 2 then
                    minClutch = 0.2
                    maxClutch = 0.4
                end

                -- Progressive clutch tightening
                local progress = 1.0 - (psg_engageTimer / psg_engageDelay)
                local clutchValue = minClutch + progress * (maxClutch - minClutch)

                carPhys.clutch = clutchValue
            else
                -- Downshift: do NOT drag the clutch
                -- Just cut gas and let the engine rise freely
                carPhys.clutch = 0.0
            end
        end

        if psg_engageTimer <= 0 then
            carPhys.clutch = 0.0
            carPhys.gas    = 0.0
            --carPhys.brake  = 0.0
            --carPhys.brake = 0.0   --engineBrake
            psg_engaged     = psg_preselected   -- added
            carPhys.requestedGearIndex = psg_engaged
        end
    end


    --------------------------------------------------------------------
    -- 5. CLEAR AC INPUT FLAGS (important!)
    --------------------------------------------------------------------
    carPhys.gearUp = false
    carPhys.gearDown = false

    --------------------------------------------------------------------
    -- 6. UPDATE LAST INPUT STATE
    --------------------------------------------------------------------
    psg_lastLever  = lever
    psg_lastClutch = clutchInput

    carPhys.controllerInputs[49] = psg_preselected       -- pre-selected gear saved for other scripts/UI
end