# Mechanical Realism Framework for Assetto Corsa (MRF)

## About

Assetto Corsa has fantastic physics, but many races still end up being little more than endless hotlapping. The goal of this project is to add deeper **mechanical realism** so that managing the car becomes part of the challenge, not just chasing the next fast lap.

This release introduces the **GEC mechanical systems framework**, a Lua-based script ecosystem designed primarily for **vintage racing cars**.

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

## Credits

* SLIGHTLYMADESTUDIOS / Tunari - made the first iteration and showed the way to proceed further
* kapasaki - took the project a giant leap forward an into a whole new level
* DimitriHarkov - finished the electricity system and made the preselector part
* SwitchPro and Ustahl - wrote the throttle model script
* Garamond247 - started the project, made some clumsy stuff for others to improve and supervised the project all along

If you have any comments or suggestions, you find us from the CVR Discord: https://discord.gg/pBFzwUw74m
For more info on how to use all the features see: https://vintageracers.eu/news/setup-guide-for-interwar-cars/

