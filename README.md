# Mechanical Realism Framework for Assetto Corsa (MRF)

## About

Assetto Corsa has fantastic physics, but many races still end up being little more than endless hotlapping. The goal of this project is to add deeper **mechanical realism** so that managing the car becomes part of the challenge, not just chasing the next fast lap.

This release introduces the **Mechanical Realism Framework**, a Lua-based script ecosystem designed primarily for **vintage racing cars**.

To make it easy to try, the framework is packaged here as a ready-to-drive car (shared with permission from *nicecuppatea*). The car itself is only a demonstration platform — the real purpose of this release is the **script framework**, which modders can integrate into their own cars.

The goal of releasing it publicly is simple:
to make deeper mechanical realism features available to other modders and encourage collaboration and experimentation.

The system was originally developed for **interwar era racing (1920–1939)** and simulates aspects of racecars that are often ignored in sim racing, such as electrical systems, mechanical wear, and operational management.

It is intended for people who enjoy racing where the challenge is not only lap time, but also **mechanical sympathy and race management**.

## Background

The project began several years ago when I was planning a championship featuring cars from this era. Around the same time I learned how Lua scripts could be integrated with Assetto Corsa mods and started experimenting with ways to push realism further.

What began as a small experiment quickly turned into a much larger project. The more systems were added, the more interesting the racing experience became.

The project has now reached a level of maturity where it feels ready for a **public release**, although development is still ongoing. What you see here is essentially a snapshot of the current state of the framework.

## Features

The full feature list is quite extensive, but here are the main highlights:

* Starter / stalling system
* Additional engine damage models (spark plugs, fuel pump, oil pressure, supercharger/turbo and valve issues)
* Additional brake damage from strong collisions
* Cumulative brake wear
* Different fuel mixtures (Rich / Normal / Lean / Push) affecting performance, cooling and engine stress
* Cooling system simulation with radiator damage, airflow effects, and overheating behaviour
* Radiator shutters adjustable from cockpit
* Overheating visual effects (steam) and failure states
* Dirt and track surface effects on cooling and tyre wear
* Gear losses / gearbox slip issues
* Tyre punctures influenced by wear, surfaces and collisions
* Ability to carry spare tyres and change them roadside
* Optional roadside tyre stacks placed around the track (1930s style)
* Fuel tank puncture possibility in collisions
* Fuel starvation on long high-G corners when running low fuel
* Engine stress from overrevving or low rev driving
* Reduced cooling when following other cars closely
* Electrical system simulation (battery / dynamo / dual ignition)
* Dynamo belt failure or slipping in rain
* Support for Wilson-type preselector gearboxes
* Improved throttle model support (external download due to license limitations)
* Repairable mechanical issues via pits or roadside procedures
* Optional feedback systems including AC messages, Driver Manual app guidance, and dashboard gauges

Most mechanical failures are designed **not to cause an immediate DNF**, but to create problems that drivers must manage or repair during the race.

## Current Scope and development status

The current version focuses on **interwar era cars**, but the system is designed to be modular and adaptable. Support for **later decades and additional mechanical systems** is planned for future development. 

This project is **still under active development** and will likely evolve over time. Expect improvements, restructuring, and new systems as the framework continues to grow. The project is though published as is and we offer no support. We are open for suggestions to further enhance this and feedback in general is very welcome. 

## AI Status

The features are developed exclusively for online use, so the focus has been solely on human operated driving. At the moment, AI drivers do **not interact with the mechanical systems** and effectively ignore them, however simplified AI support is planned for future versions.

## License & Usage

The script is released under the **MIT License**, meaning you are free to:

* Use it in your own mods
* Modify and adapt it
* Use it in free or commercial projects

If you extend or improve the system, contributing those improvements back to the project is strongly encouraged.

## Contributing

If you are interested in improving the script, adapting it for other eras, or helping expand the realism systems, contributions and pull requests are welcome.

The overall goal is simple: **to make deeper mechanical realism more common in Assetto Corsa mods as that's what I wish to see more in the scene.**

## Installation and integration

Installing the framework requires you have access to cars data that exists in data and extension folders. If those doesn't exist you need to unpack the `data.acd` file and then implement and edit the necessary files. If you wish to use the car in online, you need to pack the data into a new `data.acd` file.

The framework also utilises improved throttle model, which is not included due to lisencing differencies, but it's strongly recommended to download (https://discord.com/channels/453595061788344330/1331330678893183058) it too and include to the framework. It requires that you uncomment its calling from `script.lua` (rows 54 and 1777).

The script also relies into some CSP features and using extended physics is strongly recommended to get all the features. Always use the latest CSP version unless it has some deal braking issues for you. 

The script is divided into multiple files. Here's the short description of them:

### Lua files

- `data/car_parameters.lua` - this file should contain all per car adjustable data. All other files should be used as is.
- `data/electricity.lua` - this contains all electricity feature stuff
- `data/failure_rate_handling.lua` - this handles all the functions that affect dynamically to mechanical issue probabilities
- `data/script_psg.lua` - this has functionality for preselector gearbox
- `data/script_switch_throttle_model.lua` - the improved throttle model. It really makes a difference, but can't be included here. Contains instructions to download it's content from CSP Discord
- `data/script.lua` - the main loop functionality
- `data/supecharger.lua` - handles the supercharger issues
- `extension/car_parameters.lua` - contains position for radiator cap for steam effect
- `extension/chattyjeff.lua` - the original talking riding mechanic. This is to be removed in the future (transferred to external app)
- `extension/electricity_ext.lua` - controls the battery's effect on lights
- `extension/extra_visual_effects.lua` - control the visual effects of the script like steam from radiator and smoke from exploded supercharger
- `extension/psg.lua` - some sounds for preselector gearbox

### Other files

- `data/engine_map0_rich.lut` - rich fuel mix effect on engine torque
- `data/engine_map1_normal.lut` - normal fuel mix effect on engine torque
- `data/engine_map2_lean.lut` - lean fuel mix effect on engine torque
- `data/engine_map3_push.lut` - push fuel mix effect on engine torque
- `data/engine_mixture.lut` - defines the fuel mixture options for setup
- `data/mechanic_setup.lut` - just a boolean lut for setup
- `data/radiator.lut` - defines the radiator shutter options for setup
- `data/sparewheels.lut` - defines the sparewheel options for setup
- `extension/sfx/*.*` - sounds used by the script
- `extension/watertemp_display.ini` - defines the custom script (watertemp and ammeter) gauges in car's dashboard

### Existing files you may need to modify

- `data/brakes.ini` - add the brake duct options for setup
- `data/drivetrain.ini` - add the preselector animation keys
- `data/engine.ini` - add the fuel mix and throttle model sections
- `data/setup.ini` - add setup items for radiator, brake ducts and fuel mix + some other script specific stuff
- `extension/ext_config.ini` - add the Extra button behaviour section

## In depth documentation

This car uses a configurable Custom Shaders Patch (CSP) Lua car-physics
ecosystem. It adds period-appropriate reliability, fluids, cooling, electrical,
drivetrain, tyre, brake and repair behaviour while retaining Assetto Corsa's
normal driving model. The same `data` Lua files can be copied to another car;
adapt that car primarily through `data/script_car_parameters.lua`, then keep
the matching CSP setup entries in `data/setup.ini`.

### Features

- Mechanical reliability: spark-plug fouling, fuel-pump faults, oil-pressure
  faults, valve damage, gearbox failures, turbo/supercharger faults and
  overrev/lugging stress.
- Engine temperature: radiator and air-cooled thermal models, cooling-intake
  adjustment, body-damage cooling loss, heat-related power loss and overheat
  damage.
- Air-cooled hardware: fan-belt slip or failure, generator loss, fan/shroud
  damage, pit repair and roadside belt replacement.
- Oil and fuel systems: oil pressure, tank capacity/consumption, automatic or
  manual oil pumping, tank punctures, fuel leaks, optional manual fuel-tank
  pressurisation and oil-spill data for companion online scripts.
- Drivetrain: H-pattern, non-synchromesh and double-clutch rules, dogbox,
  Wilson preselector and Cotal electric gearbox support.
- Tyres and brakes: wear, surface-sensitive punctures, crash blowouts, spare
  wheels, roadside tyre changes, brake wear and brake blanking.
- Electrical system: battery charge/capacity, alternator output, damage,
  overheating, belt repair and weak-battery ignition effects.
- Repairs and feedback: pit repair queues, roadside service where appropriate,
  overhead messages, Lua Debug outputs, CVR Pit Crew app integration and AI
  mechanical issues.
- CVR Pit Crew can also initiate one supported roadside service while the car
  is stopped outside the pit box. It offers only punctured tyres, spark plugs
  and belt-driven charging/fan faults that the car can actually repair there.
- Crash effects: controlled engine-fire outputs for an engine destroyed in a
  sufficiently severe impact. Visual particles are configured separately in
  `extension/car_parameters.lua`.

### CSP Integration

#### Fuel mixture and engine maps

`data/setup.ini` exposes CSP's `[ENGINE_MAPS]` control. The matching
`data/engine_mixture.lut` defines the visible map names and map indexes:

```text
Rich|0
Normal|1
Lean|2
Push|3
```

The driver can change maps with CSP's Engine Map control. Lua reads the active
map from `thisCar.fuelMap`; the parameter tables use the same order, but Lua
table indexes are one-based:

```lua
-- Lua table order: rich, normal, lean, push
engineHeatGainEngineMapFactors = {0.90, 1.00, 1.20, 1.30}
sparkPlugEngineMapFactors = {1.20, 1.00, 0.82, 0.58}
```

Keep `engine_mixture.lut`, the setup map indexes and every `*EngineMapFactors`
table aligned. If a car needs fewer maps, keep the four map slots and make the
unused maps equivalent to Normal rather than changing their indexes.

#### Custom CSP setup items

The Lua script reads these IDs from `data/setup.ini`:

| ID | Purpose |
| --- | --- |
| `RADIATOR` | Cooling-intake shielding or shutters. It also works for air-cooled intake restriction. |
| `SPARE_WHEELS` | Number of carried spare wheels for roadside tyre service. |
| `BRAKE_DUCT_F`, `BRAKE_DUCT_R` | Brake blanking, brake cooling and associated drag. |
| `DOUBLE_CLUTCH_GEARBOX` | Optional non-synchromesh/double-clutch behaviour. |
| `MANUAL_OIL_PUMP` | Requires Extra C oil-pump operation when enabled. |
| `MANUAL_FUEL_PRESSURE` | Requires Extra G fuel-tank air pumping when enabled. |
| `OVERHEAD_MESSAGES` | Enables or disables Lua system messages. |

Do not rename or remove an ID used by the script. For a feature a car does not
use, keep its setup item with a disabled default or a one-value LUT.

#### CSP outputs for instruments and apps

The script publishes state through `CPHYS_SCRIPT_n` controller inputs. This
allows digital instruments, Lua apps and visual scripts to read live data. The
following assignments are the compatibility map for this ecosystem. Inputs not
listed here are unused/reserved and should not be repurposed in a compatible
car copy.

| Input | Value | Notes |
| --- | --- | --- |
| `0` | Display coolant/temperature | Degrees C. Air-cooled cars receive a lagged head/engine display value. |
| `1` | Direct engine temperature | Degrees C. |
| `2` | Spare wheels | Current carried-spare count. `-1` means trackside supply. |
| `3` | Roadside tyre-service stop timer | Seconds stopped while the tyre-service routine is active. |
| `4` | Brake damage | Boolean. |
| `5` | Idle RPM target | RPM used by the starter/stall system. |
| `6` | Engine RPM | Live physics RPM exposed by the starter/stall system. |
| `7` | Oil-pressure failure active | Boolean progressive engine-failure state. |
| `8` | Valve failure active | Boolean. |
| `9` | Fuel-pump failed | Boolean. |
| `10` | Spark-plug failure active | Boolean. |
| `11` | Brake fade | Fraction from `0` to `maxBrakeFade`. |
| `12` | Gearbox repair active | Boolean. |
| `13` | Fuel-pump repair active | Boolean. |
| `14` | Broken gear present | Boolean. |
| `15` | Body cooling damage | Boolean, for radiator or configured air-cooling intake damage. |
| `16` | Tyre puncture present | Boolean. |
| `17` | Spare-tyre stock empty | Boolean. |
| `20` | Altitude | CSP altitude value. |
| `21` | Air density | CSP air-density value. |
| `22` | Forced induction installed | Boolean for CSP turbo/supercharger hardware. |
| `23` | Boost limit exceeded | Boolean. |
| `24` | Failed turbo/supercharger count | Number of failed units. |
| `25` | Turbo failure smoke trigger | Boolean visual/event signal. |
| `26` | Reset brake wear on tyre change | Boolean configuration state. |
| `27` | Race pit-teleport lockout | Boolean. |
| `28` | CSP fuel mixture/engine map | `0=Rich`, `1=Normal`, `2=Lean`, `3=Push`. |
| `29` | Cooling intake/shutter setup | Setup index from `RADIATOR`. |
| `30` | Turbo enabled | Boolean. |
| `31` | Nearest tyre-stack distance | Metres along the track spline. |
| `32` | Overrev state | `0=normal`, `1=warning`, `2=severe`. |
| `33` | Fuel leakage damage | Boolean. |
| `34` | Low-fuel starvation threshold | Litres from `fuelExhaustionAmount`, not current fuel level. |
| `35-38` | Spark, fuel-pump, oil-pressure and valve failure rates | Current random-roll denominators, in that order. Higher means rarer. |
| `39` | Brake fade start | Brake wear level where fade begins. |
| `40` | Brake wear level | `0-1000` cumulative brake-wear scale. |
| `41` | Low-RPM state | Boolean. |
| `42` | Roadside tyre-service state | `0=idle`, `1=fetching tyre`, `2=changing tyre`, `3=complete`. |
| `43` | Net electrical flow | Amps. Positive charges the battery; negative discharges it. |
| `44` | Battery charge | Percentage. |
| `45` | Battery maximum capacity | Percentage. |
| `46` | Alternator operating | Boolean. |
| `47` | Alternator output | Amps. |
| `48` | Alternator health | Fraction from `0` to `1`. |
| `49` | Wilson preselector selected gear | Gear index. Only relevant to PSG cars. |
| `50` | Wilson preselector shift animation | Boolean. Only relevant to PSG cars. |
| `51` | Ignition type | `1=magneto`, `2=battery`, `3=hybrid`. |
| `52` | Alternator belt repair active | Boolean. |
| `53` | Oil pressure | PSI. |
| `54` | Oil tank quantity | Litres. |
| `55` | Oil tank fill fraction | `0=empty`, `1=full`. |
| `56` | Manual oil pump active | Boolean. |
| `57` | Oil-pressure damage active | Boolean. |
| `58` | Oil pit service active | Boolean. |
| `59` | Oil tank leaking | Boolean. |
| `60` | Oil leak rate | Litres per minute. |
| `61` | Oil pump damaged | Boolean. |
| `62` | Oil pump efficiency | Fraction from `0` to `1`. |
| `63` | Manual fuel pressurisation enabled | Boolean. |
| `64` | Fuel-tank pressure | PSI. |
| `65` | Fuel pressure pump active | Boolean. |
| `66` | Fuel pressure low | Boolean. |
| `67` | Fuel-pressure fuel cut active | Boolean. |
| `68` | Fuel pressure fraction | Current pressure divided by target pressure. |
| `69` | Fouled spark-plug count | Count. |
| `70` | Dead-cylinder count | Count. |
| `71` | Spark-plug power loss | Fraction from `0` to `1`. |
| `72` | Spark-plug service active | Boolean. |
| `73` | Cooling-system type | `1=radiator`, `2=air`. |
| `74` | Air-cooling fault state | `0=OK`, `1=belt slip`, `2=belt broken`, `3=fan/shroud damage`. |
| `75` | Air-cooling fan efficiency | Fraction from `0` to `1`. |
| `76` | Generator efficiency | Fraction from `0` to `1`. |
| `77` | Fan-belt stress | Cumulative stress value. |
| `78` | Air-cooling repair active | Boolean. |
| `79` | Air-cooling repair progress | Fraction from `0` to `1`. |
| `80` | Engine crash fire active | Boolean visual trigger. |
| `81` | Engine crash fire intensity | Fraction from `0` to `1`. |
| `82` | Engine crash fire time remaining | Fraction from `1` at ignition to `0` at expiry. |
| `83` | PSG animationState helper | float from neutral to highest gear, so for 4 gears: from `1` to `5` |
| `84` | Air-cooling fan-drive type | `0=not air cooled`, `1=shared belt`, `2=separate belt`, `3=gear driven`, `4=direct driven`, `5=no mechanical fan`. |

### Per-Car Tuning

Make normal car-specific changes in `data/script_car_parameters.lua`. Start
with the groups below, test the car at race pace and in pit/repair scenarios,
then make small changes. Higher random-failure denominators mean rarer faults.

#### Core reliability

- `failureRateSessionRandomness`: session-to-session reliability variation;
  set `0` for fully repeatable testing.
- `sparkPlugFailureRateNominalValue`, `fuelPumpFailureRateNominalValue`,
  `valveFailureRateNominalValue`, `oilPressureFailureRateNominalValue`:
  base failure rarity. Use higher values for a more reliable engine.
- `*EngineMapFactors`: four values in Rich, Normal, Lean, Push order. Values
  above `1.0` reduce risk, while values below `1.0` increase it.
- `valveReferenceRPM`, `oilPressureReferenceRPM`: set around the RPM where
  sustained hard running should begin to create meaningful stress.

#### Fuel mixture and engine heat

- `engineHeatGainEngineMapFactors`: heat generated by each CSP engine map.
  Keep Rich below Normal and Push above Normal unless the real engine requires
  a different relationship.
- `engineHeatGainMultiplier`, `engineIdleHeatGainCelsiusPerSecond`,
  `engineFullLoadHeatGainCelsiusPerSecond`: establish the car's normal race
  temperature before tuning damage thresholds.
- `engineTemperaturePowerCurve`: power reduction as temperature rises. Keep
  full power through the real engine's normal operating range, then reduce it
  progressively before severe damage.

#### Cooling system

- `coolingSystemType`: `COOLING_SYSTEM_RADIATOR` or `COOLING_SYSTEM_AIR`.
- `coolingDamageSides = {front, rear, left, right}`: body areas whose damage
  obstructs the main cooling flow. Examples: front radiator
  `{true, false, false, false}`, sidepod radiators `{false, false, true, true}`
  and rear-engine air cooling `{false, true, false, false}`.
- `airCoolingFanShroudDamageSides = {front, rear, left, right}`: collision
  areas that can damage an air-cooled fan or shroud. Keep this separate from
  intake damage: for a rear-engine car it is usually `{false, true, false,
  false}`. AC side damage spans the entire car length, so include a side only
  when a side impact can genuinely reach the fan/shroud.
- `engineOverheatWarningTemperatureCelsius`,
  `engineOverheatDamageStartTemperatureCelsius`,
  `engineOverheatSeizureTemperatureCelsius`: choose these from the engine's
  plausible head, oil or coolant limits and keep a sensible gap between them.
- Radiator cars: `radiatorStillAirCoolingPerSecond`,
  `radiatorAirflowCoolingPerSecond`, `radiatorDamageCoolingLoss` and shutter
  settings determine stationary, speed-based and damaged cooling.
- Air-cooled cars: `airCoolingStillCoolingPerSecond`,
  `airCoolingFanCoolingPerSecond`, `airCoolingRamAirCoolingPerSecond`,
  `airCoolingFanReferenceRpm` and `airCoolingDamageCoolingLoss` determine
  fan and road-speed cooling. Tune these against ambient temperature, race
  speed and full-load RPM.
- Air-cooled fan drive: set `airCoolingFanDriveType` to the real arrangement:
  `AIR_COOLING_FAN_DRIVE_SHARED_BELT` (fan and generator share a belt),
  `AIR_COOLING_FAN_DRIVE_SEPARATE_BELT`,
  `AIR_COOLING_FAN_DRIVE_GEAR_DRIVEN`,
  `AIR_COOLING_FAN_DRIVE_DIRECT_DRIVEN`, or `AIR_COOLING_FAN_DRIVE_NONE` for
  ram-air-only cooling. Belt slip/break faults and roadside belt changes apply
  only to the two belt-driven types. Gear/direct fans can still suffer
  pit-only fan or shroud damage; a no-fan layout has no fan repair item.

#### Oil and fuel systems

- `oilTankCapacityLitres`, `oilOptimalPressurePsi`,
  `oilLowPressureWarningPsi`, `oilCriticalPressurePsi` and
  `oilPressureReferenceRpm`: match the engine's oil system first.
- `oilAutomaticPumpAssistantEnabled`: use `true` for a conventional automatic
  pressure system, or `false` for a driver-operated/manual oil system.
- `oilBaseConsumptionLitresPerMinute`, `oilDemandConsumptionLitresPerMinute`:
  normal oil use at light and hard running.
- `oilLeakageDamageSides`, `oilLeakageDamageThreshold`,
  `oilLeakageDamageChance`, `oilLeakageRateMinLitresPerMinute`,
  `oilLeakageRateMaxLitresPerMinute`: crash-puncture location, severity and
  leak-rate range. The tank still drains without an online spill script.
- `manualFuelPressurizationEnabled` and `fuelTank*` values: enable only for
  cars with a driver-managed pressure-fed fuel system.
- `fuelLeakageDamageSides`, `fuelLeakageDamageThreshold` and
  `fuelLeakageDamageChance`: define fuel-tank crash vulnerability.

#### Drivetrain, starting and electricity

- `gearboxType`: select the real gearbox before adjusting any related values.
  Enable double-clutch or dogbox rules only where they are historically and
  mechanically appropriate.
- `doubleClutch*` and `dogbox*`: tune clutch travel, neutral time, RPM
  tolerance and damage only after testing with the intended shifter hardware.
- `engineIdleRpm`, `engineLowRpmStallGraceSeconds`,
  `engineLowRpmStallSaveThrottle`, `engineBumpStart*`: set the engine's idle,
  stall recovery window and bump-start behaviour.
- `ignitionType`: `1` magneto, `2` battery, `3` hybrid. Use the battery and
  alternator parameters only for cars that genuinely use this system.
- `batteryDamageSides` and `alternatorDamageSides`: body zones in `{front,
  rear, left, right}` which can crash-damage each component. Place them where
  the battery and generator/alternator physically sit; each selected zone is
  averaged, so selecting extra sides makes any one impact less severe.
- `suspensionShockThreshold`: wheel damper speed in m/s above which sustained
  harsh suspension movement gradually reduces battery capacity. Start around
  `3.0` for a normally secured post-war lead-acid battery; lower values make
  ordinary kerbs and rough surfaces progressively more damaging.
- `alternatorOutputRpmOffset`, `alternatorOutputRpmRange`,
  `alternatorOutputMaxAmps`, `batteryCapacityAh` and electrical loads should
  give stable charging at normal racing RPM without making idling unrealistically
  powerful.

#### Tyres, brakes, forced induction and AI

- `tyrePunctureRate*`, `tyreBlowDamageChange*`, `tyreWear*` and
  `tyreTypeFactors`: set for the era, surface and intended tyre compounds.
- `pitTyreChangesCanRunWithRepairs`: `true` lets tyre changes run alongside
  mechanical repairs; set `false` when one crew must complete its work before
  the other begins. Roadside tyre service is unaffected.
- `spareWheelMass`, spare-wheel LUT and tyre replacement times: balance period
  practice with the car's packaging and race format.
- `baseWearRate`, `brakeFadeStart`, `maxBrakeFade`, `maxBrakeTorque` and brake
  blanking: match the brake type and expected race distance.
- `turboFailure*` and `turboBoostAfterFailurePercent*`: leave irrelevant for
  naturally aspirated cars; tune only when the car has CSP turbo hardware.
- `aiMechanicalIssuesMode`: `1` off, `2` mild, `3` realistic. Keep AI failure
  rates more conservative than player-facing features for stable races.

### Validation Checklist

1. Test cold start, idle, full-load laps and cooldown at representative ambient
   temperatures.
2. Test every fuel mixture and verify heat, reliability and performance match
   its intended role.
3. Test a pit stop with each enabled repair plus any enabled roadside service.
4. Test collisions on each configured `coolingDamageSides`, oil-tank and
   fuel-tank side.
5. Check Lua Debug and any `CPHYS_SCRIPT_n` instruments or companion apps
   after changing controller output behaviour.

## Credits

* SLIGHTLYMADESTUDIOS / Tunari - made the first iteration and showed the way to proceed further
* kapasaki - took the project a giant leap forward an into a whole new level
* DimitriHarkov - finished the electricity system and made the preselector part
* SwitchPro and Ustahl - wrote the throttle model script
* Garamond247 - started the project, made some clumsy stuff for others to improve and supervised the project all along

If you have any comments or suggestions, you find us from the CVR Discord: https://discord.gg/pBFzwUw74m
For more info on how to use all the features see: https://vintageracers.eu/news/setup-guide-for-interwar-cars/

