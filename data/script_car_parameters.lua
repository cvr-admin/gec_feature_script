-- Car-specific tuning for the CSP Lua car-physics script.
--
-- This file is meant to be the main place for adapting the script ecosystem to
-- a particular car. Values here are read by script.lua and the subsystem files
-- such as script_thermal.lua, script_oil.lua, script_fuel.lua and
-- script_failure_rate_handling.lua.
--
-- Engine map/fuel mix order used by the tables below:
--   1 = rich, 2 = normal, 3 = lean, 4 = push

local engineDamageRPMThreshold = ac.INIConfig.carData(0, 'engine.ini'):get('DAMAGE', 'RPM_THRESHOLD', 8000)

-- ============================================================================
-- Random Mechanical Failure Rates
-- ============================================================================
--
-- These values are random-roll denominators. Higher numbers mean less frequent
-- failures. Most random failures are rolled every 2 seconds while the engine is
-- running. The script can reduce the base rates during a run because of abuse:
-- overrevving, low-RPM lugging, high coolant temperature, dirty air, etc.
--
-- Engine map factors multiply the current base rate:
--   > 1.0 = safer, fewer failures
--   = 1.0 = baseline
--   < 1.0 = riskier, more failures

math.randomseed(os.time() + math.random(0, 1000))

-- Per-session reliability scatter. At each full car reset/session start, the
-- script rolls a small multiplier for each random failure family. This keeps
-- the same tuned nominal values below, but makes the car start each session a
-- little different. 0.04 means +/-4%. Set to 0 to disable. The actual
-- randomization helper lives in script_failure_rate_handling.lua.
failureRateSessionRandomness = 0.04

-- Spark plugs. Fouling is tracked per plug instead of using engine-life damage.
-- The Alfa Romeo P3 used an inline-8 layout; two plugs per cylinder is kept
-- configurable so the same script can fit other interwar engines.
sparkPlugFailureRateNominalValue = 80000
sparkPlugEngineMapFactors = {1.20, 1.0, 0.82, 0.58}
sparkPlugFailureRateMinimumValue = 50
sparkPlugCylinderCount = 8
sparkPlugPerCylinder = 1
sparkPlugPitChangeFirstPlugSeconds = 10
sparkPlugPitChangeAdditionalPlugSeconds = 4
sparkPlugRoadsideChangeFirstPlugSeconds = 35
sparkPlugRoadsideChangeAdditionalPlugSeconds = 10
sparkPlugRoadsideReactionTime = 4
sparkPlugCascadeRiskPerFouledPlug = 0.25

-- Fuel pump: intermittent fuel cuts after failure. Repair happens in pits.
fuelPumpFailureRateNominalValue = 100000
fuelPumpRepairTime = math.random(45, 150)
fuelPumpPitTimer = 0
fuelPumpRepairInProgress = false
fuelPumpEngineMapFactors = {1.08, 1.0, 0.92, 0.72}
fuelPumpFailureRateMinimumValue = 50

-- Valves: after the initial roll, damage progresses with RPM over time.
valveFailureRateNominalValue = 120000
valveFailureMaxDamage = 100
valveFailureBaseTime = 75.0
valveFailureElapsed = 0
valveFailureActive = false
valveReferenceRPM = math.max(engineDamageRPMThreshold * (2 / 3), 1)
valveEngineMapFactors = {1.25, 1.0, 0.78, 0.50}
valveFailureRateMinimumValue = 50

-- Oil-pressure fault roll: this damages the oil pump/system. The oil-pressure
-- simulation then decides whether lubrication is still adequate or engine
-- damage should begin.
oilPressureFailureRateNominalValue = 128000.0
oilPressureFailureMaxDamage = 100
oilPressureFailureBaseTime = 70.0
oilPressureFailureElapsed = 0
oilPressureFailureActive = false
oilPressureReferenceRPM = math.max(engineDamageRPMThreshold * 0.55, 1)
oilPressureEngineMapFactors = {1.15, 1.0, 0.90, 0.68}
oilPressureFailureRateMinimumValue = 50

-- ============================================================================
-- Oil System
-- ============================================================================
--
-- This script can represent early manual oiling or a pressure-fed/dry-sump
-- system. For this Offenhauser sprint car the automatic assistant is enabled,
-- so the oil system still simulates pressure, consumption, leaks and damage,
-- but the driver does not need to press Extra C for manual pump strokes.

-- Total oil carried. Larger values suit dry-sump race engines and longer runs;
-- smaller values suit harsh total-loss systems.
oilTankCapacityLitres = 20

-- Normal pressure target and warning/damage thresholds. Pressure-fed racing
-- engines can use much higher pressures than the 20-45 psi range typical of
-- earlier low-pressure systems.
oilOptimalPressurePsi = 35
oilLowPressureWarningPsi = 22
oilCriticalPressurePsi = 12

-- RPM where oil demand is considered normal hard running. Lower values make
-- pressure drop sooner in ordinary running; higher values are more forgiving.
oilPressureReferenceRpm = math.max(engineDamageRPMThreshold * 0.78, 1)

-- Manual-pump values still matter if the assistant is disabled in setup/code.
oilPumpLitresPerStroke = 0.08
oilPressurePumpStrokeGainPsi = 4.0
oilAutomaticPumpAssistantEnabled = true

-- Dry-sump gallery behavior. These override script_oil.lua's generic defaults.
oilEngineGalleryInitialLitres = 0.58
oilEngineGalleryTargetLitres = 0.58
oilEngineGalleryMaximumLitres = 0.90
oilAutomaticPumpStartPressurePsi = 28
oilPressureRecoveryPressurePsi = 20
oilPressureRiseRatePerSecond = 2.8
oilPressureFallRatePerSecond = 1.15

-- Oil use while running. Base use is always present; demand use scales with RPM
-- and throttle. Raise demand use if long full-throttle running should draw down
-- the tank faster.
oilBaseConsumptionLitresPerMinute = 0.012
oilDemandConsumptionLitresPerMinute = 0.055

-- Damage from oil starvation.
oilLowPressureGraceSeconds = 7.0
oilLowPressureEngineDamagePerSecond = 1.2
oilPitRefillTimeSeconds = 12.0

-- Random oil-pressure failures damage the oil pump first. These values decide
-- how severe that pump damage is after the random failure roll succeeds.
-- Lower efficiency values and higher pressure-loss values make oil-pressure
-- failures turn into real low-pressure damage sooner. Higher efficiency values
-- and lower pressure loss make the warning more survivable.
oilPressurePumpFailureEfficiencyMin = 0.25
oilPressurePumpFailureEfficiencyMax = 0.65
oilDamagedPumpPressureLossPsi = 10

-- Oil-tank puncture from body damage. Sides are {front, rear, left, right}.
-- The initial rate is chosen from this wide range using both impact severity
-- and a random component. It then tapers strongly as the tank empties.
oilLeakageDamageSides = {true, false, true, true}
oilLeakageDamageThreshold = 70
oilLeakageDamageChance = 0.40
oilLeakageRateMinLitresPerMinute = 1.0
oilLeakageRateMaxLitresPerMinute = 30.0

-- ============================================================================
-- Gearbox
-- ============================================================================
--
-- Gear failure rate is also a random-roll denominator: higher means safer.
-- This sprint car uses a simple one-forward-gear arrangement, so the active
-- gearbox type is left as the default H-pattern/manual path. The other gearbox
-- tuning blocks remain here so this file can be reused for cars that need them.

gearFailureRate = 85000
boostedGearFailureRate = gearFailureRate
gearboxRepairTime = math.random(20, 90)
gearboxPitTimer = 0
gearboxRepairInProgress = false

-- Once a gear has failed, its driveline effect fades in instead of applying at
-- full strength immediately. The final broken-gear effect still uses a random
-- clutch value in this range every frame, matching the old behavior but with a
-- short onset.
gearFailureRampTimeMinSeconds = 2.0
gearFailureRampTimeMaxSeconds = 5.0
gearFailureClutchMin = 0.10
gearFailureClutchMax = 0.50

-- Gearbox type:
--   1 = AC default H-pattern/manual gearbox
--   2 = Wilson-style preselector gearbox
--   3 = non-synchromesh H-pattern gearbox requiring double-clutch technique
--   4 = 1970s/1980s racing dogbox H-pattern gearbox
--   5 = electrical Cotal/autoclutch gearbox
GEARBOX_TYPE_H_PATTERN = 1
GEARBOX_TYPE_WILSON_PRESELECTOR = 2
GEARBOX_TYPE_NON_SYNCHRO = 3
GEARBOX_TYPE_DOGBOX = 4
GEARBOX_TYPE_COTAL_ELECTRIC = 5
gearboxType = GEARBOX_TYPE_NON_SYNCHRO

function gearboxTypeIs(selectedGearboxType)
    return gearboxType == selectedGearboxType
end

function isWilsonPreselectorGearboxEnabled()
    return gearboxTypeIs(GEARBOX_TYPE_WILSON_PRESELECTOR)
end

function isNonSynchroGearboxEnabled()
    return gearboxTypeIs(GEARBOX_TYPE_NON_SYNCHRO)
end

function isDogboxGearboxEnabled()
    return gearboxTypeIs(GEARBOX_TYPE_DOGBOX)
end

function isCotalElectricGearboxEnabled()
    return gearboxTypeIs(GEARBOX_TYPE_COTAL_ELECTRIC)
end

-- Compatibility values for older modules/configs. Do not set these by hand;
-- change gearboxType above instead.
gearboxIsPSG = isWilsonPreselectorGearboxEnabled()
gearboxIsElectrical = isCotalElectricGearboxEnabled()
edwardianGearboxDoubleClutchEnabled = isNonSynchroGearboxEnabled()
dogboxGearboxEnabled = isDogboxGearboxEnabled()
psg_ds_protection = false

-- Non-synchromesh H-pattern behavior. Active only when gearboxType is
-- GEARBOX_TYPE_NON_SYNCHRO.
edwardianGearboxSetupToggleEnabled = true
doubleClutchOnlyWithHShifter = true
doubleClutchClutchInThreshold = 0.72
doubleClutchNeutralClutchOutThreshold = 0.35
doubleClutchNeutralClutchReleaseTravel = 0.40
doubleClutchMinimumNeutralTime = 0.12
doubleClutchMinimumBlipGas = 0.18
doubleClutchMinimumBlipRpmRise = 100
doubleClutchDownshiftRpmTolerance = 850
doubleClutchDownshiftClutchInRequired = true
doubleClutchUpshiftNeutralTime = 0.08
doubleClutchUpshiftClutchInRequired = true
doubleClutchUpshiftRequiresNeutralClutchRelease = true
doubleClutchUpshiftRpmTolerance = 700
doubleClutchBadShiftGrindTime = 0.55
doubleClutchBadShiftDamageK = 0.16
doubleClutchMessageCooldown = 4.0

-- Dogbox H-pattern behavior. Active only when gearboxType is
-- GEARBOX_TYPE_DOGBOX.
dogboxRequiresHShifter = true
dogboxMinimumPatchVersionCode = 3749
dogboxTorqueLockThresholdNm = 65
dogboxStrictPreloadWindow = true
dogboxPreloadTimeoutSeconds = 0.45
dogboxEnableBlockedShiftGrinding = true
dogboxBlockedShiftGrindDamageK = 0.06
dogboxBlockedShiftMessageCooldown = 3.0
dogboxDisableOriginalDrivetrainDamageRpmWindow = true
dogboxUpshiftLiftDropThreshold = 0.18
dogboxUpshiftCoastGasThreshold = 0.08
dogboxUpshiftPreloadLookbackSeconds = 0.35
dogboxUpshiftClutchMessageThreshold = 0.70
dogboxDownshiftClutchThreshold = 0.70
dogboxMisshiftGrindDamageK = 0.35
dogboxMisshiftGrindTime = 0.50
dogboxMisshiftGearDamage = 0.08
dogboxGearFailureDamage = 1.00

-- ============================================================================
-- Throttle Response
-- ============================================================================
--
-- These values affect the Lua throttle shaping in script_throttle.lua, not the
-- actual power curve. The curve is defined by a gamma and a slope. Gamma below 1 makes the curve more aggressive at low throttle; above 1 makes it softer. Slope above 1 makes them more aggressive in the mid-range; below 1 makes them softer. The curve is applied to the throttle input after all other processing, so it shapes the final power delivery and can be used to simulate different throttle linkages or driver aids.

throttle_curve_gamma = 0.65
throttle_curve_slope = 3.0

-- ============================================================================
-- Engine Temperature and Cooling System
-- ============================================================================
--
-- Cooling system type:
--   1 = water cooling with coolant/radiator/shutters
--   2 = air cooling with direct cylinder/head airflow
--
-- Water-cooled cars track engine core temperature and coolant temperature
-- separately. Air-cooled cars bypass coolant exchange and cool the engine
-- directly with fan/RPM airflow plus road-speed airflow.

COOLING_SYSTEM_RADIATOR = 1
COOLING_SYSTEM_AIR = 2
coolingSystemType = COOLING_SYSTEM_RADIATOR

function coolingSystemTypeIs(selectedCoolingSystemType)
    return coolingSystemType == selectedCoolingSystemType
end

function isRadiatorCoolingSystemEnabled()
    return coolingSystemTypeIs(COOLING_SYSTEM_RADIATOR)
end

function isAirCoolingSystemEnabled()
    return coolingSystemTypeIs(COOLING_SYSTEM_AIR)
end

engineColdStartTemperatureOffsetCelsius = 2.0

engineOverheatWarningTemperatureCelsius = 100
engineOverheatDamageStartTemperatureCelsius = 112.0
engineOverheatSeizureTemperatureCelsius = 130
engineOverheatBaseDamagePerSecond = 1.2
engineOverheatSevereDamagePerSecond = 24.0

-- Engine crash fire visual trigger. This does not add gameplay damage by
-- itself; it tells the extension visual script to emit flames/smoke if engine
-- life reaches zero from a hard crash.
engineCrashFireEnabled = true
engineCrashFireEngineLifeThreshold = 0
engineCrashFireDurationSeconds = 35
engineCrashFireDamageDeltaThreshold = 45
engineCrashFireMinimumSpeedKmh = 55
engineCrashFireIntensityMin = 0.45
engineCrashFireIntensityMax = 1.0

-- Engine temperature power correction. A cold air-cooled engine is slightly
-- lazy from poor fuel vaporisation and oil drag; a very hot engine loses power
-- before it reaches hard damage/seizure temperatures.
engineTemperaturePowerEnabled = true
engineTemperaturePowerCurve = {
    {temp = -20, factor = 0.82},
    {temp = 20, factor = 0.88},
    {temp = 50, factor = 0.95},
    {temp = 70, factor = 0.985},
    {temp = 82, factor = 1.00},
    {temp = 95, factor = 1.00},
    {temp = 104, factor = 0.975},
    {temp = 112, factor = 0.92},
    {temp = 122, factor = 0.75},
    {temp = 130, factor = 0.55},
}

-- Pit cooling is a one-time service on pit entry if the engine/coolant is hot.
pitWaterCoolingTemperatureThresholdCelsius = 90
pitWaterCoolingDropCelsius = 20

engineIdleHeatGainCelsiusPerSecond = 0.24
engineFullLoadHeatGainCelsiusPerSecond = 1.45
engineHeatGainMultiplier = 0.93269

engineBlockToAmbientCoolingPerSecond = 0.004
engineBlockSpeedCoolingPerSecond = 0.00000035
engineCoolantHeatTransferPerSecond = 0.15
engineCoolantTransferBalance = 0.65

-- Low-RPM heat retention. With little fan/pump speed and no ram air, the engine
-- should cool slowly when stopped and only moderately faster at idle.
engineStoppedCoolingRpmThreshold = 100
engineStoppedStillCoolingMultiplier = 0.22
engineIdleStillCoolingMultiplier = 0.50

-- Air cooling. Still cooling is weak when the car is stopped, the fan term
-- scales with engine RPM, and ram-air cooling scales with road speed. These
-- are intentionally conservative for a 1951 pushrod air-cooled race engine:
-- it should tolerate fast running but dislike long idling, low-RPM lugging and
-- full-throttle climbing in hot weather.
airCoolingStillCoolingPerSecond = 0.0012
airCoolingFanCoolingPerSecond = 0.0065
airCoolingRamAirCoolingPerSecond = 0.00000030
airCoolingFanReferenceRpm = 4200
airCoolingFanMinimumFactor = 0.18
airCoolingFanMaximumFactor = 1.20
airCoolingDamageCoolingLoss = 0.45
-- Body areas whose damage can obstruct the main cooling flow: {front, rear, left, right}.
-- This works for both air-cooled and radiator-cooled cars. The 356 takes its
-- cooling air at the rear, so front collision damage alone does not reduce cooling.
coolingDamageSides = {true, false, false, false}
airCoolingDisplayTemperatureLagPerSecond = 0.9

-- Air-cooled fan drive. Select the actual mechanical layout rather than
-- assuming every air-cooled engine shares its fan belt with the generator.
--   SHARED_BELT: one belt drives the cooling fan and charging generator
--                (356, VW flat-four and most classic 911 layouts).
--   SEPARATE_BELT: fan and charging system have independent belts.
--   GEAR_DRIVEN: fan is driven through gears/shaft (for example Porsche 917).
--   DIRECT_DRIVEN: fan is driven directly from the crankshaft.
--   NONE: no mechanically driven fan; cooling is ram-air/ducting only.
AIR_COOLING_FAN_DRIVE_SHARED_BELT = 1
AIR_COOLING_FAN_DRIVE_SEPARATE_BELT = 2
AIR_COOLING_FAN_DRIVE_GEAR_DRIVEN = 3
AIR_COOLING_FAN_DRIVE_DIRECT_DRIVEN = 4
AIR_COOLING_FAN_DRIVE_NONE = 5
airCoolingFanDriveType = AIR_COOLING_FAN_DRIVE_SHARED_BELT

-- Belt faults are rare endurance-style issues, not arcade random events.
-- They apply only to SHARED_BELT and SEPARATE_BELT layouts. Stress builds from
-- sustained high RPM, overrevving, high engine temperature, oil contamination
-- and rear cooling-shroud damage.
airCoolingBeltSlipCoolingLossMin = 0.15
airCoolingBeltSlipCoolingLossMax = 0.35
airCoolingBeltSlipGeneratorLossMin = 0.20
airCoolingBeltSlipGeneratorLossMax = 0.45
airCoolingBeltBrokenCoolingLossMin = 0.60
airCoolingBeltBrokenCoolingLossMax = 0.90
airCoolingFanShroudDamageCoolingLossMin = 0.20
airCoolingFanShroudDamageCoolingLossMax = 0.55
airCoolingBeltPitRepairTimeMinSeconds = 60
airCoolingBeltPitRepairTimeMaxSeconds = 120
airCoolingBeltRoadsideRepairTimeMinSeconds = 240
airCoolingBeltRoadsideRepairTimeMaxSeconds = 480
airCoolingFanShroudPitRepairTimeMinSeconds = 60
airCoolingFanShroudPitRepairTimeMaxSeconds = 120
airCoolingBeltStressSlipThreshold = 1.0
airCoolingBeltStressBrokenThreshold = 1.6
airCoolingBeltStressBuildPerSecond = 0.0014
airCoolingBeltStressRecoveryPerSecond = 0.00025
-- Fan/shroud impact areas: {front, rear, left, right}. AC side damage spans
-- the whole car, so this rear-engined 356 uses rear-only damage here.
airCoolingFanShroudDamageSides = {false, true, false, false}
airCoolingBeltRearDamageThreshold = 35
airCoolingBeltRearDamageBrokenThreshold = 70

engineIdleRpm = ac.INIConfig.carData(0, 'engine.ini'):get('ENGINE_DATA', 'MINIMUM', 900)
engineLowRpmCoolingFullRpm = engineIdleRpm * 2.0
engineStallClutchInThreshold = 0.70
engineStarterStartTimeMinSeconds = 2
engineStarterStartTimeMaxSeconds = 5

-- Bump-start and low-RPM stall settings. These are per-car tuning values:
-- heavier flywheel/lower compression engines can use lower values; peaky,
-- high-compression or weak-idle engines can use higher values.
--
-- engineBumpStartMinSpeedKmh is an absolute safety floor. Below this road speed
-- the script will not bump-start even if the selected gear implies enough RPM.
engineBumpStartMinSpeedKmh = 12

-- Minimum engine RPM implied by road speed and selected gear for a stalled
-- engine to catch when the clutch is released. Raise this if the car restarts
-- too easily in tall gears; lower it if realistic bump-starts fail too often.
engineBumpStartMinDrivenRpm = math.max(engineIdleRpm * 0.75, 450)

-- Time the engine may remain at a genuine stall condition before it dies.
-- A genuine stall condition means the clutch is engaged and the drivetrain
-- cannot sustain usable engine RPM. Releasing the clutch, restoring RPM, or
-- gaining enough road speed cancels the countdown. Use a shorter time for a
-- light, peaky racing engine and a longer time for a heavy-flywheel road
-- engine. 1.0-1.6 seconds is a sensible normal range.
engineLowRpmStallGraceSeconds = 1.4

-- Driver throttle input which slows the low-RPM stall countdown while the
-- engine tries to recover. This does not create RPM or prevent a stall by
-- itself; it simply gives engine inertia time to respond. 0.18 means 18%
-- throttle. Lower values make recovery easier, higher values require a more
-- deliberate throttle input. 0.12-0.25 is a sensible normal range.
engineLowRpmStallSaveThrottle = 0.18

radiatorStillAirCoolingPerSecond = 0.008
radiatorAirflowCoolingPerSecond = 0.00000105
radiatorDamageCoolingLoss = 0.85

-- Fuel-map heat generation. Order is rich, normal, lean, push. Rich reduces
-- combustion heat; lean and push add heat. Radiator efficiency is not changed
-- by fuel mix.
engineHeatGainEngineMapFactors = {0.9, 1.0, 1.2, 1.3}

-- Radiator shutter/tape setup. If radiatorShutterAdjustEnabled is false, the
-- setup value is read from the setup menu only. If true, Extra E closes the
-- radiator one step and Extra F opens it one step while allowed by
-- remFlags.radiatorShutter or while in pits.
radiatorShutterAdjustEnabled = true

-- Remote adjustment flags. True allows cockpit adjustment while driving; false
-- restricts adjustment to pits/grid/menu where script.lua temporarily re-enables
-- controls.
remFlags = {
    radiatorShutter = true,
    fuelMix = true,
}

-- ============================================================================
-- Tyres, Punctures and Roadside Service
-- ============================================================================

spareWheelMass = 22
spareWheelPos = vec3(0, 0, 0.5)

-- Tyre pressure above this value triggers a fast leak/blow event.
tyreBlowPressure = 75

-- Virtual-kilometre tyre life. Actual life is randomized between tyreBasevKM
-- and tyreBasevKM + tyrevKMvariance, weighted by biasStrength. Lower
-- biasStrength favors longer lives; higher values spread failures more evenly.
tyreBasevKM = 1
tyrevKMvariance = 70
biasStrength = 0.45

-- Time the car must be stopped with the required input before roadside tyre
-- replacement begins.
tyreReplacementReactionTime = 5

-- Pit service workflow. Set false for cars whose tyre crew cannot work while
-- mechanical repairs are underway. Roadside tyre service is unaffected.
pitTyreChangesCanRunWithRepairs = false

-- Slow-puncture random-roll denominators by surface. Higher means safer.
tyrePunctureRateAsphalt = 173800
tyrePunctureRateGravel = 56600
tyrePunctureRateIce = 217250
tyrePunctureDeflateFactor = {}
tyrePuncturePressureFactor = {}

-- Random deflation time range. A value of 18 empties the tyre in about 1.8 s;
-- 1200 is about 120 s.
minPunctureDeflateFactor = 20
maxPunctureDeflateFactor = 1800

-- AC tyre wear multipliers by surface.
tyreWearAsphalt = 1.0
tyreWearGravel = 1.2
tyreWearIce = 1.0

-- Tyre short names from tyres.ini. The factor is used in puncture probability
-- from accumulated wear: lower values make the compound less fragile from wear.
tyreTypeFactors = {
    {"SH", 1.2},
    {"HS", 4},
    {"LS", 4},
    {"HSI", 1},
    {"FS", 4},
}

-- Crash puncture thresholds. Damage change is checked per impact; larger hits
-- can force a puncture or blow both tyres on the damaged side.
tyreBlowDamageChange = 30
tyreBlowCrashingRate = 2
tyreBlowDamageChangeHard = 60
tyreBlowDamageChangeMax = 90

-- ============================================================================
-- Brake Wear
-- ============================================================================

brakeWearLevel = 0.0
maxBrakeRPM = 1500
baseWearRate = 0.0005
brakeFadeStart = 500
maxBrakeFade = 0.95
maxBrakeTorque = ac.INIConfig.carData(0, 'brakes.ini'):get('DATA', 'MAX_TORQUE', 770)

-- Brake wear LUT: {wheel-speed factor, wear multiplier}.
wearLUT = {
    {0.0, 0.0},   -- No wear when stopped
    {0.3, 0.12},   -- Low speed wear
    {0.7, 0.45},   -- Medium speed wear
    {1.0, 1.00},   -- Peak efficiency
    {1.5, 2.20},   -- Over-speed wear
    {2.0, 3.50},    -- Dangerous over-revs
}
resetBrakeWearAtTyreChange = true

-- ============================================================================
-- Supercharger / Turbo Failure
-- ============================================================================
--
-- This Offy is naturally aspirated. These values are kept dormant/high so the
-- shared subsystem will not become aggressive if a stray boost controller is
-- present. Leave turboOnOffButtonEnabled false unless the car genuinely has a
-- driver-controlled boost system.

turboFailureRate = 180000
turboFailureRateProgression = 10
rateDecreaseStepMax = 36
turboFailureRateMin = 50000
turboFailureFactorMin = 1000
turboFailureFactorMax = 2
turboBoostAfterFailurePercentMin = 0
turboBoostAfterFailurePercentMax = 50
turboExplosionRate = 2
engineLifeAfterExplosionPercentMin = 30
engineLifeAfterExplosionPercentMax = 70
turboFailureEngineOverheatingRate = 2
engineHeatGainMultTurbo = engineHeatGainMultiplier + 0.1
turboOnOffButtonEnabled = false

-- ============================================================================
-- Driving-Abuse Failure-Rate Modifiers
-- ============================================================================
--
-- These values do not cause failures directly. They reduce the active failure
-- rate denominators over time, making later random failure rolls more likely.

-- Overrevving. Thresholds are based on engine.ini [DAMAGE] RPM_THRESHOLD.
-- Warning threshold is a fraction of the soft overrev threshold, not of the raw
-- RPM_THRESHOLD. With RPM_THRESHOLD=7300 and these values:
--   warning ~= 6832 rpm, soft damage ~= 6972 rpm, hard damage ~= 7191 rpm.
overrevvingThresholdFactor = 0.938
overrevvingThresholdFactorHigh = 0.975
overrevvingProgressionExponent = 1.108
overrevvingRateDecreaseStepFactor = 0.4
overrevvingHighRateDecreaseStepFactor = 1
overrevvingWarningThresholdFactor = 0.97

-- Low-RPM lugging. Below this fraction of RPM_THRESHOLD, spark/fuel/oil rates
-- degrade and radiator efficiency is reduced to represent poor airflow/pump
-- speed while the car is moving.
lowRpmThreshold = 0.5
radiatorEfficiencyLowRpmMultiplier = 1.1

-- Dirty air/traffic. If another car is close ahead above the speed threshold,
-- fuel pump, valve and oil pressure rates degrade, radiator efficiency drops,
-- and dirt clogging builds faster.
closeCarInFrontSpeedThreshold = 50
closeCarInFrontDistanceThreshold = 40
closeCarInFrontDistanceMin = 5

-- High coolant temperature starts increasing failure-rate degradation.
highEngineTempThreshold = 88

-- Low fuel level increases fuel-pump risk.
fuelLevelThreshold = 10
fuelPumpLowFuelStep = 5

-- Dirt and radiator clogging. radiatorEfficiencyDustMultiplier is an immediate
-- dusty-air surface effect. The clog values are cumulative: dirt running slowly
-- fills the radiator, reducing cooling by up to radiatorDustClogMaxCoolingLoss.
-- Pit service removes only radiatorDustClogPitCleanFraction of the accumulated
-- clog.
radiatorEfficiencyDustMultiplier = 0.9
radiatorDustClogBuildRatePerSecond = 0.0005
radiatorDustClogSpeedReferenceKmh = 115
radiatorDustClogFollowingMultiplier = 2.25
radiatorDustClogMaxCoolingLoss = 0.28
radiatorDustClogPitCleanFraction = 0.50

-- ============================================================================
-- Fuel System
-- ============================================================================

-- Fuel tank damage/leakage. Sides are {front, rear, left, right}.
fuelLeakageDamageSides = {false, true, true, true}
fuelLeakageDamageThreshold = 40
fuelLeakageDamageChance = 0.42

-- Fuel pickup starvation at low fuel and lateral G.
fuelExhaustionAmount = 30
fuelExhaustionGForceThreshold = 0.9

-- Manual fuel tank pressurization. Disabled for this car. If enabled, the
-- driver or automatic assistant must keep tank pressure high enough or fuel
-- feed cuts can occur.
manualFuelPressurizationEnabled = true
fuelTankOptimalPressurePsi = 3.0
fuelTankLowPressureWarningPsi = 1.8
fuelTankMinimumFuelFeedPressurePsi = 1.0
fuelTankPressurePumpGainPsi = 0.35
fuelTankPressureLossPerFuelLitre = 0.08
fuelTankPressureNaturalLossPerSecond = 0.003
fuelTankPressureLeakDamageLossPerSecond = 0.018

-- ============================================================================
-- Ignition and Electricity
-- ============================================================================
--
-- ignitionType:
--   1 = magneto, 2 = battery, 3 = hybrid
--
-- Magneto ignition disables the active battery/alternator failure update path,
-- but the values are kept for cars that switch to battery or hybrid ignition.

ignitionType = 2

-- Body areas for electrical crash damage: {front, rear, left, right}.
-- The 356 battery is in the front luggage compartment; its generator and
-- shared fan belt are at the rear with the engine.
batteryDamageSides = {true, false, false, false}
alternatorDamageSides = {true, false, false, false}

alternatorFailureRate = 15000
alternatorRepairTime = math.random(100, 200)
tempThresholdElectricity = 95
-- Wheel damper speed in m/s. 3.0 targets hard kerbs, potholes and impacts;
-- normal suspension movement should remain below it.
suspensionShockThreshold = 3.0
alternatorOutputRpmOffset = math.max(engineDamageRPMThreshold * 0.125, 1)
alternatorOutputRpmRange = math.max(engineDamageRPMThreshold * 0.708, 1)
alternatorOutputExponent = 1.6
alternatorOutputMaxAmps = 18.0
alternatorOK = true
alternatorHealth = 1.0
batteryCurrentCharge = 100.0
batteryMaxCapacity = 100.0
batteryCapacityAh = 12.0
isRepairingBelt = false
beltRepairTimer = 0
powerDrainSystems = 19.20768
powerDrainHeadlights = 308.64198

-- ============================================================================
-- AI Mechanical Issues
-- ============================================================================
--
-- 1 = off, 2 = mild, 3 = realistic. Mild gives AI tyre punctures and generic
-- limp-to-pit issues. Realistic adds more mechanical sources and allows some
-- issues to become DNFs.

aiMechanicalIssuesMode = 3
aiIssueDNFPercent = 90
aiIssueRollInterval = 1.0
aiIssuePitSearchDistanceKm = 2.0
aiIssuePitServiceTime = 14.0
aiIssueRoadsideTyreChangeTime = 28.0
aiIssueSlowdownMultiplierMin = 0.10
aiIssueSlowdownMultiplierMax = 0.70
aiIssueSideRoadMaxSpeedKmh = 135
aiIssueSideSteer = 0.06
aiIssueDNFSteer = 0.12
aiIssueLoggingEnabled = false
aiIssueDebugOutputsEnabled = false
