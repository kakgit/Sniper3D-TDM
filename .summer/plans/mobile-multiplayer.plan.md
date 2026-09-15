---
name: mobile-multiplayer
overview: >-
  Make the sniper TDM run on 2-3 phones: touch controls, an Android build, then
  rooms, team balancing and accounts.
createdAt: '2026-09-14T14:08:28.667Z'
todos:
  - id: touch-controls
    content: >-
      Add a touch control layer and Android-ready display settings so the game
      is playable on a phone with no keyboard or mouse.
    status: completed
  - id: android-export
    content: >-
      Guide the one-time Android export setup and produce the first APK to
      install on 2-3 phones.
    status: completed
  - id: rooms-teams
    content: >-
      Turn the single host/join session into rooms of 20 slots (10 per team)
      with joiners auto-placed on the emptier team.
    status: in_progress
  - id: bot-fill
    content: >-
      Keep the AI stand-ins running inside a session to fill empty slots and
      hand a slot over as each human joins.
    status: pending
  - id: accounts-login
    content: >-
      Add first-time registration and login using the account model chosen for
      the project.
    status: pending
  - id: room-list
    content: Add a room list screen so a player can browse rooms and join one.
    status: pending
  - id: phone-test
    content: >-
      Playtest on 2-3 phones together and fix the networking, balance and touch
      issues that show up.
    status: pending
  - id: dedicated-server
    content: >-
      Build and host the headless room server that owns rooms, teams and matches
      over the internet, since the host is now a server rather than a phone.
    status: pending
  - id: accounts-api
    content: >-
      Build and host the account backend that registration and login talk to
      over HTTPS.
    status: pending
---
# Mobile multiplayer build plan

## Where the project stands today

- **LAN session already exists.** `NetworkManager` autoload (ENet listen server, port 8910, `MAX_PLAYERS = 8`) with host/join by typed IP, and `mp_menu.tscn` for the host/join panel. Its buttons are ordinary Controls, so touch can press them.
- **`net_session.gd`** spawns one player body per peer under `World/Players` and syncs movement at 20 Hz. Two things matter for this plan: it **switches the AI stand-ins OFF** for the duration of a session, and team assignment is hardcoded (host = team 0, joiners = team 1).
- **Input is keyboard + mouse only.** Look lives in `player_controller.gd` and needs `MOUSE_MODE_CAPTURED`; the rifle reads the `shoot` / `aim` / `reload` actions. There is no touch layer, so a phone currently has no way to move, look or shoot.
- **Not present yet:** accounts, room list, team balancing, Android export preset. `renderer/rendering_method` is already `mobile`, and stretch is `canvas_items` / `expand`.

## Decisions (answered)

- Transport: over the internet. The room owner is a dedicated server, not a phone.
- Accounts: real accounts on a backend, so one login works on any phone.
- Bots: bots fill empty slots, and each joining human takes one over on the emptier team.

Consequence: the host is no longer a phone, so rooms, teams, bot handover and match state
belong on the server, and both the game server and the accounts API need hosting the user
must provide. Until that server exists, the current phone-hosts-a-room code stays the test
harness for playing over Wi-Fi on the same network.

## Working order

1. Get the APK onto 2-3 phones and test touch on the same Wi-Fi. Validates the controls and
   the core feel before any server is built. User action, with the export preset in place.
2. Rooms, team balancing and bot handover, built to run inside the game.
3. Dedicated server: headless room owner, so the host can drop out.
4. Accounts backend and the registration/login flow against it.
5. Room list, then a real multi-phone playtest.

## Milestones

1. **Touch controls** - left joystick for movement, right-side drag for look, buttons for fire / aim / reload / crouch / sprint / jump / menu, plus landscape orientation and a phone base viewport. Desktop keyboard and mouse keep working exactly as they do now.
2. **Android build** - one-time setup (build templates, SDK path, debug keystore) then Export, and install on 2-3 phones.
3. **Rooms and teams** - rooms with 20 slots, 10 per team, and each joiner auto-placed on the emptier team.
4. **Bot fill** - bots hold empty slots inside a session and hand the slot over as humans arrive.
5. **Accounts** - first-time registration and login, on the model chosen in chat.
6. **Room list** - browse rooms and join one.
7. **Phone test** - real test on 2-3 phones together.

## Honest limits

- I cannot build the APK from here. There is no export action in my toolset; the build is the editor's Export dialog on your machine, after a one-time Android SDK + build-template setup. My part is making the project ready so that step is one click, and writing the setup steps out for you.
- No account system works without a place to store accounts. If real accounts are wanted, that is a server you host and pay for; I can write both sides, but I cannot create the hosting or the credentials.
- Things only a phone test can settle: how the touch layout feels, aim sensitivity, and the frame rate on your actual handsets.

## Verified facts driving the current design

- The mid barricade at z = 0 stays solid at every height, and each team's half is reachable only by spawning in it. Rooms and spawn logic must respect that.
- Mouse capture must always be releasable (ESC -> `MOUSE_MODE_VISIBLE`); on touch the cursor is never captured at all.
- Bots are the `target` group (`target.tscn`), the player is the `player` group, match state is in `match_manager.gd` in the `match` group.
