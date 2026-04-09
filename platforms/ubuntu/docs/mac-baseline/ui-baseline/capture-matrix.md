# SkyBridge Ubuntu ↔ Mac UI Capture Matrix

Fields: `ID | Page | State | Theme | Locale | Expected`

| ID | Page | State | Theme | Locale | Expected |
|---|---|---|---|---|---|
| UI-CAP-001 | Login | Idle | Light | en-US | Title/subtitle/form-card rhythm matches Mac baseline |
| UI-CAP-002 | Login | Error | Light | en-US | Error text hierarchy and button disabled/loading state match |
| UI-CAP-003 | Dashboard | Discovering | Light | en-US | Status cards/panels/dot indicator spacing and colors match |
| UI-CAP-004 | Dashboard | Connected + streaming | Dark | en-US | Active state chips and panel contrast match |
| UI-CAP-005 | Devices | Empty | Light | en-US | Empty/list transition and status text placement match |
| UI-CAP-006 | Devices | Populated | Dark | en-US | Device row icon, chevron, status alignment match |
| UI-CAP-007 | Transfers | Empty | Light | en-US | Empty state icon/title/description hierarchy match |
| UI-CAP-008 | Transfers | In-progress + completed | Dark | en-US | Progress bar, filename, status row rhythm match |
| UI-CAP-009 | Settings | Default | Light | en-US | Header/group spacing/toggle row rhythm match |
| UI-CAP-010 | Settings | Security section | Dark | en-US | Badges/warnings/destructive accents match Mac baseline |
| UI-CAP-011 | Tray/Notifications | Incoming transfer prompt | Light | en-US | Notification title/body/actions wording and grouping match |
| UI-CAP-012 | Tray/Notifications | Remote control prompt | Dark | en-US | Notification severity hierarchy and actions match |
| UI-CAP-013 | USB | Attached device inventory | Light | en-US | USB trust badges, route hints, and sidebar rhythm match Mac baseline |
| UI-CAP-014 | Remote | Trusted active sessions | Dark | en-US | Session cards, preview state, and control affordances match Mac baseline |
| UI-CAP-015 | Monitor | Live system snapshot | Light | en-US | Metrics cards, alert rail, and monitoring summary hierarchy match Mac baseline |

## Pass rule

- All matrix items must have Ubuntu and Mac captures plus visual diff outputs.
- No blocking mismatch in primary action, state colors, or critical copy hierarchy.
