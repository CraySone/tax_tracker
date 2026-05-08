# Land Barons - Arise

Land Barons - Arise is an ArcheAge Classic addon for tracking land, taxes, loans, and farm timers in one place.

## Features

### Land Tracking
- Save land with name, type, zone, coordinates, tax amount, and tax status
- Zone-based land list with expandable entries
- Urgency colors for paid, unpaid, and overdue land
- Autofill land details from target where possible
- Multiple character support

### Tax Reminders
- Countdown timers for land taxes
- Overdue detection with count-up timers
- Login and logout reminders for overdue or soon-due taxes
- Automatic tax payment detection, currently WIP and needs testing

### Loans
- Track rental payments from players
- Attach loans to saved land
- Mark loans as paid, unpaid, or overdue
- Add notes to loan entries
- Loans are removed when their linked land is deleted

### Farm Tracker
Farm tracking is based on the original Farm Tracker addon and extended for Land Barons - Arise.

- Track farm timers from hovered objects
- Assign tracked farm objects to your saved land
- Optional autotracker button for faster tracking
- Group farm objects by entity name
- Show earliest and latest timers per group
- Expand groups to see individual timers
- Tracking overlay for selected farms
- Delete single timers, groups, or tracked farms from the UI

### Special Location Tracking
Cooled Tree Trunks and similar fixed-location objects can be tracked through saved custom locations.

You can capture known locations, name them, and the addon will automatically use the closest saved location based on your player position when creating the farm entry.

## Basic Usage

1. Target your land in-game.
2. Open the addon editor.
3. Click autofill from target.
4. Fill missing fields if needed.
5. Click add land.

Your land will appear under its zone. Expanding the zone shows all saved land entries, including tax timers and action buttons.

## Naming Tips

Renaming land helps the addon match tax payments more accurately.

Recommended examples:

- `Silo (name)`
- `Scarecrow (name)`
- `Improved (name)`

This is especially helpful when you own multiple land plots of the same size and type.

## Farm Usage

1. Open the Farm Tracker window.
2. Add or choose one of your saved lands.
3. Hover farm objects while holding your selected modifier key.
4. Choose the land the object belongs to.
5. The addon creates or updates the farm entry.

With Autotracker enabled, the flow is faster and tracked objects can be added automatically when possible.

## Notes

This addon is still being tested. Some features, especially automatic tax payment detection and farm autotracking, may need more real-world testing across different land setups.

Bug reports and tester feedback are welcome.
