# Turn Tactics — rules reconciliation

How the slideshow, the owner's later decisions, the configurable catalog and older rooms fit together.
The server (`supabase/022_rules_engine.sql`) is the single source of these values; the app reads them
from each room's `config` and never hard-codes a cost or a cutoff.

## 1. Rules versions

| Version | Rooms | Start range | Proposal cost | Cutoff (Pacific) | Elimination | Board | Dispatch coordinates |
|---|---|---|---|---|---|---|---|
| `legacy-v0.5` | created before migration 016 (no version stored) | 2 | 4 | 19:00 | balance kept, unspendable | host chooses side 3–24 | `(column, row)` |
| `slideshow-2026-11` | created by 016 | 3 | 5 | 18:00 | points forfeited | slideshow table; **six players undefined** | `(column, row)` |
| `owner-2026-11` | **all new rooms** | **4** | 5 | 18:00 | points forfeited | slideshow table **plus six players → 8 × 8** | chess (`a1` lower-left) |

* An existing room keeps its version. Nothing in a room's stored state is rewritten by the migrations
  or by loading the new frontend; in particular nobody's range increases.
* A version the server does not know raises `Unsupported rules version` — it never silently behaves
  like a legacy room.
* A host may deliberately move a room to `owner-2026-11` from the host desk (must type `MIGRATE`;
  announced in Dispatch). In a lobby, seats take the new starting values. In a scheduled or running
  game only costs, cutoff and elimination behaviour change; no range, heart or point is altered.

## 2. Slideshow defaults that still apply (all versions unless noted)

Host/referee is separate and cannot act · 5–20 players · 3 starting hearts · unique random squares ·
opens at the next Pacific midnight with no spendable point before then · one point at opening and at
each later midnight for living players · stockpiling allowed · move 1 point, one orthogonal square,
never onto an occupied square · attack 1 point on an accepted hit, shielded target rejects for free ·
transfer exactly 1 point, no fee, never to the host · shield 2 points, ends at midnight, no duplicate ·
range upgrade 2 points, permanent · withdrawal free and permanent · eliminated players vote; strict
majority of ballots cast gives one bonus point at midnight; ties and no ballots give nothing; ballots
private · last survivor wins.

Board table: 5–6 → 8, 7 → 9, 8–9 → 10, 10 → 11, 11–12 → 12, 13–14 → 13, 15–16 → 14, 17–20 → 15.

## 3. Owner overrides (this release)

1. Starting targeting range **4** for newly created rooms.
2. **Six players use 8 × 8** (the slideshow left it undefined).
3. Accounts are required to host or join; preserved guest seats keep working in their rooms.
4. Six-character invitations; the 12-character room code remains the canonical identifier.
5. Chess coordinates with `a1` at the lower-left (display only: server x/y are unchanged, `rank = size − y`).
6. Eliminated players keep room chat **and** direct messages; the host cannot mute anyone.
7. Finished-game chat is deleted 24 hours after the match ends.

## 4. Mechanics the host can change (rules desk catalog)

Every item is typed, range-checked and applied by the server. Several effects can be combined in one
amendment; they apply together or not at all. Each effect is either *immediate* or *at the next
midnight reset* (applied exactly once, before that reset's income; cancellable until then).

**Settings (change future behaviour — never grant, refund or replay anything):**

| Setting | Range | Notes |
|---|---|---|
| Move / attack / shield / range-upgrade cost | 0–20 | |
| Rule proposal cost | 0–50 | applies to later approvals |
| Daily income | 0–20 | from the next reset; nothing is granted now |
| Eliminated-player vote bonus | 0–10 | |
| Base targeting range | 1–30 | shifts every player's current range by the difference; purchased upgrades are kept |
| Targeting range cap | 0–30 (0 = none) | upgrades above the cap are kept but ineffective while it stands |
| Moves per player per day | 0–20 (0 = unlimited) | moves already made today count |
| Shield duration | 1–7 resets | new shields only; active shields keep their expiry |
| Starting hearts | 1–10 | lobby only |
| Survivors who share victory | 1–20 | ends the match at once if that many or fewer are alive |
| Daily action cutoff hour | 1–24 (24 = all day) | no effect in test rooms (manual clock) |
| Moves, attacks, transfers, shields, range upgrades | on / off | a disabled action is rejected without charge |

**One-time effects (change existing state):**

* Adjust **points**, **hearts** or **range** by ±1–50 for every living player or one named living
  player. Points floor at 0, range at 1. Hearts reaching 0 eliminate (shields do not block this);
  an amendment that would eliminate every living player is refused.
* End all active shields.

**Not configurable by design:** transfer amount (always exactly 1), withdrawal cost, board size once
players are placed, revival, moving pieces, back-dated income, replaying past events.

## 5. Host-enforced written agreements

Anything outside the catalog is recorded as a **written rule**. It is published with a
“Host-enforced” label in the rule history and Dispatch. The engine does not apply it; the referee
does. Example: “No attacking on Sundays.”

## 6. Proposals and amendments

* Player proposal: costs the room's proposal cost, charged **only on approval**, never reserved;
  pending and rejected proposals are visible to the author and host only.
* The host may approve as proposed, or compose catalog effects for it. Payment and effects happen in
  one transaction; approval re-checks that the proposer is alive and can pay; a retry never charges twice.
* Host amendment: attributed to the host, needs a public title and reason, charges nobody.
* Every approved change is public history. A *correction* is a new amendment that references the old
  one; it cannot erase history, revive players or refund actions already taken.

## 7. Protected boundaries (no rule can change these)

Message privacy · authentication and recovery · identity (no impersonation; reserved names) ·
private resources and ballots · chat access for eliminated players · no host muting ·
no executable text of any kind (effects are data, validated against a fixed list).
