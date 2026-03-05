# Contributing to the Mechanical Realism Framework (MRF)

Thank you for your interest in improving the MRF script ecosystem.

This project aims to expand the mechanical realism of vintage race cars in Assetto Corsa by simulating systems that are usually ignored in sim racing, such as electrical systems, component wear, and mechanical management.

Because realism and historical accuracy are central goals, contributions should be well-reasoned and documented.

## Contribution Principles

When proposing a change, please keep the following in mind:

* Changes should improve **mechanical realism or historical authenticity**.
* Avoid arbitrary gameplay tweaks or balancing changes unless they are supported by historical evidence or technical reasoning.
* Features should remain **modular and reusable** so they can be integrated into other vintage car mods.

## How to Contribute

1. Fork the repository
2. Create a new branch
3. Make your changes
4. Open a Pull Request

Example:

```
git checkout -b improve-alternator-model
```

## Coding Guidelines

### Lua scripting

* Keep functions modular and reusable.
* Avoid hard-coded car values when possible.
* Use parameters from `car_parameters.lua` for tunable values.

### Performance

Scripts run every frame in Assetto Corsa, so:

* Avoid heavy loops
* Avoid unnecessary calculations
* Cache values when possible

### Naming

Use descriptive names such as:

```
alternatorHealth
batteryChargeRate
radiatorEfficiency
```

## Historical Considerations

If your contribution modifies mechanical behaviour, please briefly explain:

* What real system the change represents
* The era of cars it applies to
* Any sources or references used

This helps maintain historical consistency across the framework.

## Testing

Before submitting a PR:

* Test the change in Assetto Corsa
* Confirm no Lua errors occur
* Confirm the feature behaves correctly during long runs

## Feature Scope

This framework currently focuses on systems such as:

* Electrical systems (battery / alternator / magneto)
* Mechanical component wear
* Cooling systems
* Engine stress and damage
* Vintage driving management features

Large new systems should be discussed in an **Issue** before implementation.

## Respect the Framework

This project is intended to be a **shared realism toolkit for vintage racing mods**.

Please aim to improve the framework rather than adapting it for a single car only.

Thank you for contributing.
