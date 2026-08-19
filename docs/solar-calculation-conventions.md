# Solar calculation conventions and reference corpus

**Method identifier:** `meeusNOAAV1`  
**Supported civil years:** 1800 through 2100, inclusive  
**Reviewed:** 2026-08-19

This note freezes the numerical contract for the first solar-position overlay. The implementation
is original Swift based on the equations published by NOAA's Global Monitoring Laboratory, which
in turn cites Jean Meeus' *Astronomical Algorithms*. It does not copy or link the NREL SPA source.

Primary references:

- [NOAA Solar Calculation Details](https://gml.noaa.gov/grad/solcalc/calcdetails.html), including
  the piecewise atmospheric-refraction model and stated accuracy limits.
- [NOAA General Solar Position Calculations](https://gml.noaa.gov/grad/solcalc/solareqns.PDF),
  including the equation of time, declination, true solar time, azimuth/elevation, solar noon, and
  the 90.833-degree sunrise/sunset zenith convention.
- [NREL Solar Position Algorithm report, Appendix A.5](https://docs.nrel.gov/docs/fy08osti/34302.pdf),
  used only as an independent position fixture with a tolerance appropriate to the simpler NOAA
  method.

## Inputs and calendar

- Coordinates are finite WGS-84 latitude and longitude in degrees. Longitude is positive east.
- Position input is an absolute `Date`; the calculator never reads `TimeZone.current`.
- Civil-day events require a separately supplied fixed UTC offset from -14:00 through +14:00.
  The offset selects the reported civil day but does not alter the position at the input instant.
- Calendar conversion uses the proleptic Gregorian calendar.
- Julian date is calculated directly from the Unix epoch relation
  `JD = unixSeconds / 86400 + 2440587.5`; J2000.0 is therefore exactly 2451545.0.
- The supported range is deliberately narrower than the theoretical Meeus range. NOAA describes
  these approximations as very good from 1800 through 2100, and that range covers credible source
  photography without presenting ancient/future results with misleading confidence.

## Position equations

For Julian century `T = (JD - 2451545) / 36525`, `meeusNOAAV1` calculates geometric mean solar
longitude and anomaly, orbital eccentricity, equation of center, apparent longitude, corrected
obliquity, declination, and equation of time using the coefficients in NOAA's published equations.
True solar time combines UTC minutes, equation of time, and longitude.

- Azimuth is normalized to `0..<360` degrees clockwise from true north.
- Geometric elevation is positive above the astronomical horizon.
- Expected shadow direction is exactly the normalized solar azimuth plus 180 degrees. It is a
  direction only, never a ground-distance or shadow-length prediction.

Apparent elevation adds NOAA's piecewise refraction correction:

- no correction above 85 degrees;
- the tangent series from 5 through 85 degrees;
- the fourth-order polynomial from -0.575 through 5 degrees; and
- the low-elevation tangent expression below -0.575 degrees.

This standard-atmosphere approximation has no pressure, temperature, humidity, observer-elevation,
weather, terrain, or obstruction input. Apparent elevation and event times are consequently not
observations of the real horizon.

## Civil-day events and convergence

Solar noon, sunrise, and sunset start from NOAA's closed-form estimates and iteratively recompute
declination and equation of time at the candidate event. Each solve is capped at 12 iterations and
must stabilize within 0.0001 minute; failure produces a named `nonConvergence` error rather than a
partial value. Sunrise and sunset use a geometric zenith of 90.833 degrees, accounting
approximately for the solar disc and normal refraction.

If the sunrise hour-angle equation has no real solution, the sign distinguishes polar day from
polar night. Sunrise and sunset are then absent while solar noon remains available. A position
whose apparent elevation is below zero is explicitly marked below the horizon; map presentation
must not render it as an active Sun ray.

## Reference fixtures and tolerances

The executable corpus is in `AnalysisSolarPositionCalculatorTests.swift`.

| Fixture | Source | Checked values | Tolerance |
| --- | --- | --- | --- |
| J2000.0, 2000-01-01 12:00 UTC | Julian-date definition | 2451545.0 | `1e-9` day |
| NREL Appendix A.5, 2003-10-17 12:30:30 UTC-07 at 39.742476, -105.1786 | NREL TP-560-34302 | azimuth 194.340241 degrees; unrefracted elevation 39.872046 degrees | 0.03 degree; the app uses NOAA/Meeus rather than SPA and does not model the fixture's pressure/elevation |
| Greenwich, 2024-06-20, 51.4779, 0 | NOAA day spreadsheet, retrieved 2026-08-19 | sunrise 03:43 UTC; solar noon 12:02 UTC; sunset 20:21 UTC | 2 minutes |
| Oslo summer/winter | Generated invariant corpus | sunrise < noon < sunset; normalized bearings | exact ordering/range |
| Tromsø June/December solstices | Generated polar corpus | polar day/night; absent rise/set | exact state |
| Leap day at the date line with UTC-12 and UTC+14 | Generated offset corpus | position is invariant for the same instant | exact `Double` result |
| Civil years 1800 and 2100 across UTC-year boundaries | Generated boundary corpus | rise/set remain calculable | exact availability |
| 32 concurrent calculations | Generated concurrency corpus | deterministic `Sendable` result | exact equality |

NOAA states that rise/set calculations are theoretically accurate to about one minute between
latitudes ±72 degrees and about ten minutes outside that range, before real atmospheric variation.
UI and report wording must disclose that limitation rather than presenting test tolerance as real-
world certainty.

## Method changes

Any change to equations, constants, event horizon, refraction, supported years, convergence limits,
or output meaning requires a new `AnalysisSolarCalculationMethod` case. Existing persisted/report
evidence must retain `meeusNOAAV1`; it must not silently acquire values from a revised method.
