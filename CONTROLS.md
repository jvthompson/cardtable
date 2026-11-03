# CardTable Controls

## Window

| Key | Effect |
|-----|--------|
| F6 | Toggle between the custom title bar and a standard window frame |

## Game table

### Mouse

| Action | Effect |
|--------|--------|
| Drag a card | Move it. A card with others stacked visually on top of it carries them along as a group, including any tokens attached to them. While dragged, a single card grows to hand size over your hand and shrinks to table size over the table. |
| Hover a card in your hand | Raise it out of the fan so you can read it |
| Click a pile (2+ stacked cards) | Draw the top card into your hand |
| Drag a pile | Peel off just the top card |
| Alt + drag a pile | Move the whole pile; dropped on your hand, every card is dealt into it |
| Pile's shuffle button | Shuffle the pile and turn every card face-down |
| Click a player's avatar | Practice games: act as that seat |
| Mouse wheel over the table | Zoom in/out around the cursor |
| Middle-button drag on the table | Pan your own camera |
| Tab + drag on the table | Draw an arrow everyone can see (fades after 5 seconds) |
| Drag on empty table | Box select: every card, pile and token of yours the box touches is selected (tinted in the selection color, set in **Settings > Table**) |
| Shift + drag on empty table | Add to the selection |
| Ctrl + click a card, pile or token | Add it to or remove it from the selection |
| Click empty table | Clear the selection |
| Drag a selected item | Move the whole selection; it drops like a single card (into your hand, onto a zone, Alt onto a card to pile everything onto it) |
| Right-click | Context menu (see below) |

**Dropping a dragged card**

- On your hand (including the part of the fan that overlaps the table): inserts it between the cards it was dropped between, whether it came from the table, a zone or elsewhere in your hand. A whole pile (Alt + drag) goes in at that spot, in pile order.
- On one of your zones: puts it on top of the zone; hold **Alt** to put it on the bottom.
- On a shared pile on the table: stacks onto it.
- Near another loose card with **Alt** held: stacks onto it. Piles never mix owners: your cards only stack onto your own piles and unowned cards onto unowned piles; otherwise the card stays where it was.
- Anywhere else: moves it on the table. Anything that would end up partly off the table is pulled back fully onto it.

Opponents' cards, piles and zones are read-only: you can hover them (for the Space preview) but not draw, drag, shuffle or flip them.

### Keyboard

Hotkeys act on the card (or token, for Q / E) under the cursor and fire once per key press (holding a key doesn't repeat). F, Q / E, X and Z on a selected card act on the whole selection.

| Key | Effect | Applies to |
|-----|--------|------------|
| Space (hold) | Large preview of the hovered card, showing exactly what you can see of it | Any card |
| F | Flip face-up/face-down (a flipped token has no backside, so it just goes greyscale) | Your table cards, your hand, a shared zone's top card, your own zone's top card if the editor marked that zone Flippable, or a hovered token |
| Q / E | Rotate 90° counter-clockwise / clockwise (hold Ctrl for 45° steps) | Your cards on the table, or a hovered token |
| X | Send to your discard zone | Your cards on the table, if the game defines a discard pile |
| Z | Bring the card's stack to the front | Your cards on the table |
| 1–9 | Draw that many cards into your hand (1 on a table card moves just that card to hand) | Your piles, your zones and shared zones |
| W / A / S / D (hold) | Pan your own camera | Only your view moves |
| Home or H | Reset camera pan and zoom | |
| F1 | Show/hide the ownership border on every card | This session only |
| F2 | Toggle zone/hand backgrounds between player-color tint and black | This session only |
| F11 | Cycle the playmat area: none (default), one large shared area, one per player | This session only |
| F12 | Cycle through the game's playmats | |
| L | Open/close the Game Log (with a Save Log button) | |
| C | Open/close the chat panel (server games only) | |
| Ctrl + R | Open/close the Rulebook viewer (if the game has a rulebook.md), with a collapsible table-of-contents sidebar. Also works in the Deck Editor. | |
| Esc | Clear the selection; with nothing selected, open/close the Game Menu (save game, settings, controls, kick a player, leave/end game) | |
| Ctrl (while dropping a token) | Duplicate the token instead of moving it | Token widgets |

### Chat commands

Typed into any chat box (lobby, room, or the in-game chat panel) on a CardTable server.

| Command | Effect |
|---------|--------|
| /flip | Flips a coin and posts "flipped: Heads" or "flipped: Tails" |
| /roll dX | Rolls a die with X sides (e.g. `/roll d6`, `/roll d20`) and posts "rolled dX: &lt;result&gt;" |
| /clear | Lobby chat only, server admins only: clears the lobby chat for everyone |

### Right-click menus

| Target | Menu |
|--------|------|
| Empty table | **Widgets** (Simple Counter, Token, Pack Generator, Deck Widget when the game has deck-building zones) and **Card Library** |
| Your card | **Send to...** Hand / Discard / a zone (Top, Shuffle Into, Bottom); on the table also **Flip**, **Rotate**, **Give to** a player and **Remove Ownership** (both ask first; not offered for a card in a pile) |
| A selected card (2+ items selected) | The same actions for every selected card, plus **Create Pile Here** (piles them all at the click, in their current order) |
| Your pile | Same as a card, plus **Search...** |
| A zone | **Search...**; an empty zone that deals a built deck also offers **Load Deck...** |
| Simple Counter | Increment / Decrement / Set Value / Set Colors / Delete |
| Token | Set Color / Delete |
| Pack Generator | Open a pack from one of the game's sets / Delete |
| Your Deck Widget | Delete |

### Your hand

Your hand is drawn as a fan of cards along the bottom of the screen, and opponents' hands as fans of card backs. The shape is adjustable in **Settings > Hand**: card size, card spacing, tilt between cards, maximum fan spread, how far the resting fan sits above the hand area, and how much of a hovered card is shown. Changes apply live and are only on your screen.

### Board widgets

- Drag any widget to move it.
- **Token:** drop it on a card to attach it (it then travels with the card); drop it on empty table to detach it. Hold **Ctrl** while dropping to duplicate it.
- **Simple Counter:** double-click the right half to add 1, the left half to subtract 1.

## Deck Editor

| Action | Effect |
|--------|--------|
| Left-click a card in the pool | Add one copy to the deck |
| Right-click a card in the pool | Remove one copy |
| Click a card in the deck list | Remove one copy |
| Hover | Preview the card |
| Ctrl + R | Open/close the Rulebook viewer |
