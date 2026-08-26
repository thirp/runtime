# Odin naming conventions

Generic naming rules distilled from a cardgame codebase. Strange, I know. Prefer clarity of role over cleverness. Names should say what a thing *is* (types) or *does* (procs), not how it is implemented.

I had this document created because I like how the naming worked out and would like to repeat these standadards in future projects.

---

## Case and word shape

| Kind | Shape | Examples |
|------|--------|----------|
| Packages | `snake_case` | `card_games`, `nine_hole`, `non_empty` |
| Files / directories | `snake_case` | `session_memory.odin`, `setup_handlers.odin` |
| Types (struct, enum, union, distinct) | `PascalCase` | `GameConfig`, `SeatIndex`, `PlayingCard` |
| Enum variants | `PascalCase` | `SixCards`, `InvalidSeatIndex`, `OutOfMemory` |
| Constants | `SCREAMING_SNAKE` | `MIN_PLAYERS`, `HOLES_PER_MATCH` |
| Procs, locals, parameters, fields | `snake_case` | `join_game`, `seat_count`, `to_act` |
| Package import aliases | short `snake_case` or initials | `cg`, `ne`, `nh` |

Do not use leading underscores for “private” symbols. Package boundaries are the privacy mechanism.

---

## Packages and directories

- One package name per directory; the directory name matches the package (`non_empty/` → `package non_empty`).
- Domain or feature packages use a product/domain noun (`nine_hole`), not a technology noun.
- Shared library packages use a capability noun (`non_empty`, or parent `card_games` for shared types).
- Runnable hosts / CLIs may use `package main` in a sibling directory named `<domain>_cli`.
- Prefer short import aliases for parent or sibling packages (`import cg ".."`, `import ne "../non_empty"`).

---

## Files

Split by *role*, not by type name:

| File role | Typical contents | Example names |
|-----------|------------------|---------------|
| Types / model | Structs, enums, unions, distincts, command/event envelopes | `types.odin` |
| Value constructors & arithmetic | Smart constructors, pure value helpers | `values.odin` |
| Queries / predicates | Read-only table or collection helpers | `table.odin` |
| Domain transitions | `check_*` + apply procs for one phase or area | `setup.odin`, `play.odin`, `board.odin` |
| Handlers / orchestration | Thin glue: apply → events → result | `setup_handlers.odin`, `step.odin` |
| Lifecycle / memory | Init, reset, destroy, alloc helpers | `session_memory.odin`, `destroy.odin` |
| Tests | Same package; mirror the unit under test | `setup_test.odin`, `board_test.odin` |
| Shared test fixtures | Helpers only used by tests | `test_helpers.odin` |

Rules:

- `foo.odin` pairs with `foo_test.odin` in the same package.
- Multi-word file names stay `snake_case` (`setup_handlers.odin`).
- Avoid dumping unrelated concerns into one file; prefer a clear role name over a catch-all `utils.odin`.

---

## Types

### Structs and records

- Noun phrases in `PascalCase`: `ActiveTable`, `Scoreboard`, `SeatedPlayer`.
- Prefer domain vocabulary over implementation vocabulary (`Stock`, not `CardDeque`).
- Compound nouns put the head last when English allows: `PlayerHoleScore`, `GridPosition`.
- Empty marker structs are still named as concepts: `EmptySeat`, `ClosedTable`, `EmptyStock`.

### Distinct types (value objects)

- Wrap primitives that carry invariants: `HoleNumber`, `SeatIndex`, `SeatCount`, `Strokes`, `PlayerName`.
- Construct only through `make_<type>` (or documented aliases). Do not cast at call sites as a shortcut.

### Enums

- Type name is the category; variants are values of that category:
  - `GameVariant` → `SixCards`, `NineCards`
  - `GridRow` → `Top`, `Middle`, `Bottom`
- Error enums are closed sets ending in shared infrastructure cases when needed (`OutOfMemory`, `Internal`, `NotImplemented`).
- Use `None` (or equivalent) as the success / no-error sentinel when the enum is used as an error code, so `err != .None` / `err != nil` reads naturally.

### Unions

- Prefer `#no_nil` when every case is meaningful and nil is not a valid state.
- Name the union for the concept it represents; name arms for the alternatives:
  - `SetupTable` = `ClosedTable` | `OpenTable`
  - `GridSlot` = `FaceDownSlot` | `FaceUpSlot`
  - `StockOrEmpty` = `Stock` | `EmptyStock`
- Optional-ish shapes use `MaybeX` with explicit arms (`NoSeat` / `SomeSeat`), not nullable pointers.
- “A or empty” collections use `<Thing>OrEmpty` with a dedicated empty arm (`HandOrEmpty`, `DiscardOrEmpty`).

### Prefixed families (commands, events, states)

Keep related shapes in parallel families with a stable prefix:

| Family | Prefix | Examples |
|--------|--------|----------|
| State-machine arms | `State` | `StateSetup`, `StateAwaitingDraw`, `StateMatchComplete` |
| Intent / command payloads | `Command` | `CommandJoinGame`, `CommandDrawFromStock` |
| Phase command unions | `<Phase>Command` | `SetupCommand`, `TurnCommand` |
| Domain facts / events | `Event` | `EventPlayerJoined`, `EventHoleScored` |
| Top-level envelopes | domain noun | `GameState`, `GameCommand`, `GameEvent` |
| Focused apply results | `<Action>Result` | `DrawStockResult`, `SwapDrawnResult`, `StepResult` |
| Scoped errors | `<Context>Error` | `GameError`, `SessionEpochError`, `NumDecksError` |

Command and event names use past or imperative domain language consistently within the family (commands as intents: `CommandTakeSeat`; events as facts: `EventPlayerSeated`).

### Generics

- Parameterized types use a short `PascalCase` name: `NonEmpty`, `Result`.
- Type parameters follow Odin style (`$T`, `$Ok`, `$Err`).

---

## Constants

- `SCREAMING_SNAKE` for compile-time bounds and fixed configuration: `MIN_PLAYERS`, `MAX_PLAYERS`, `DEFAULT_SESSION_EPOCH_BYTES`.
- Prefer named constants over magic numbers at call sites.
- Typed “named values” that are not raw literals may be ordinary constants of a distinct type (`OneDeck :: NumDecks(1)`).

---

## Procedures

### General

- Verbs or verb phrases in `snake_case`: `score_grid`, `flip_slot`, `players_equal`.
- Name for the domain action, not the memory strategy (`take_seat`, not `cow_set_seat`).
- Predicates read as questions or boolean properties: `table_is_open`, `player_joined`, `slot_is_face_up`, `jokers_enabled`, `grid_all_face_up`.
- Queries that return a derived value use noun or `get_` / plain verb: `roster_count`, `grid_capacity`, `get_slot`, `slot_card`.
- Equality helpers: `<things>_equal` (`players_equal`, `playing_cards_equal`).

### Role prefixes (use deliberately)

| Prefix | Role | Returns / effect |
|--------|------|------------------|
| `make_` | Smart constructor for a value object or validated config | `Result(T, Error)` or `T` when infallible |
| `from_` | Construct from an existing representation | e.g. `from_slice`, `from_first` |
| `default_` / `empty_` | Canonical zero / starter value | `default_config`, `empty_grid` |
| `check_` | Pure policy gate for an action; no heap | Error enum (`.None` = allowed) |
| *(bare action)* | Declarative apply / transition | `Result(NextState, Error)`; **always** calls matching `check_` first |
| `handle_` | Thin orchestration: apply → attach events → package result | Step/result envelope; does not re-encode rules |
| `apply_` | Internal transition helper when the public name is already taken by a phase handler | Same purity rules as apply |
| `validate_` | Structural / geometric validity (positions, indices) | Error or bool as documented |
| `alloc_` | Allocate domain buffers (events, one-shots) | Pointer / slice + error |
| `destroy_` | Free owned resources for a value | Operates on `^T` |
| `abandon_` | Drop a root without field-by-field free (arena / epoch) | Operates on `^T` |
| `<type>_` lifecycle | Init / reset / use / destroy for a long-lived resource | `session_epoch_init`, `session_epoch_destroy` |
| `print_` / `menu_` / `read_` | Host / CLI I/O | Side-effecting |
| `*_str` | Format a value as text | `string` |
| `test_` | Unit test entry point | `proc(t: ^testing.T)` |
| `must_` | Test-only unwrap that fails the test on error | Concrete `T` |
| `fixture_` | Test-only built scenario | Domain state |

Keep the triad aligned when an action has policy + transition + handler:

```text
check_take_seat(...)  → Error
take_seat(...)        → Result(State, Error)   // calls check_ first
handle_take_seat(...) → StepResult             // calls take_seat; attaches events
```

### Subject-first helpers

When several procs operate on the same aggregate, lead with that noun:

- `grid_*` — `grid_capacity`, `grid_variant`, `grid_deal_positions`
- `seating_*` — `seating_get`, `seating_put_grid`
- `discard_*` — `discard_push`, `discard_draw`
- `scoreboard_*` — `scoreboard_append_hole`
- `session_epoch_*` — init / allocator / reset / destroy / use

### Parameter and local names

- Prefer short domain nouns: `seat`, `hole`, `grid`, `table`, `config`, `player`.
- Use `next` for an updated copy of an immutable-style value.
- Allocator parameters default to context: `allocator := context.allocator`.
- Optional location tracking: `loc := #caller_location` on alloc/teardown helpers.
- Boolean out-params use `ok` when following Odin’s `(value, ok)` pattern.

---

## Fields

- `snake_case` domain nouns: `joker_scoring`, `reveals_remaining`, `to_act`, `next_hole`.
- Avoid redundant type echoes in the field name when the type is already clear (`seat: SeatIndex`, not `seat_index: SeatIndex`), unless disambiguation is needed (`seat_count`).
- Nested “base” embeddings for shared phase data use a plain name such as `base`.

---

## Tests

- Test procs: `test_<unit>_<behavior>` in sentence-like `snake_case`.
  - Success: `test_join_game_adds_first_player`
  - Rejection: `test_check_take_seat_rejects_occupied_seat`
  - Handler wiring: `test_handle_join_game_success_emits_player_joined`
- Put policy tests next to apply (`setup_test.odin`); put thin handler tests next to handlers (`setup_handlers_test.odin`).
- Shared builders: `test_player`, `make_six_face_up`, `fixture_awaiting_draw`.
- Panic-on-err helpers for fixtures only: `must_*`.

---

## Aliases

- Use a type alias when it clarifies a role at the API boundary without a new shape:
  - `InitialRevealCommand :: CommandRevealInitial`
  - `Stock :: ne.NonEmpty(PlayingCard)`
- Prefer aliases over wrapper structs when there is no extra data or invariant.

---

## What not to do

- Do not encode allocation strategy, COW, or arena mechanics in public domain names.
- Do not use `I`/`Impl` suffixes, Hungarian prefixes, or leading underscores.
- Do not create a second vocabulary for the same concept (`chair` vs `seat`); pick one domain term and stick to it.
- Do not put business rules only inside `handle_*`; policy lives in `check_*` / apply.
- Do not name files after a single type when the file’s job is a role (`board.odin`, not `PlayerGrid.odin`).

---

## Quick checklist

1. Type? → `PascalCase` domain noun (or `State` / `Command` / `Event` family).
2. Proc? → `snake_case` verb; add `check_` / `make_` / `handle_` / `destroy_` only when that role applies.
3. Constant? → `SCREAMING_SNAKE`.
4. File? → `snake_case` role; tests as `<file>_test.odin`.
5. Package / directory? → matching `snake_case`.
6. Could this name work in another game or library with the same role pattern? If yes, the convention is holding.
