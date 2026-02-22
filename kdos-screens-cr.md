# KDOS Change Request: SCREENS Enhancements for App Integration

**Date:** 2026-02-22
**From:** bsky.f (Bluesky client)
**Priority:** Nice-to-have (client works without these; they improve UX)

---

## 1. Per-Screen Activate Handler (`SCR-ACT-XT`)

**Problem:** `DO-SELECT` is hard-coded to screen 7 (Docs). Enter/Space on
any other selectable screen is a no-op. Apps registering new screens have
no way to handle item activation.

**Proposed change (§9.1 + DO-SELECT):**

```forth
\ §9.1 — add array next to SCR-KEY-XT:
CREATE SCR-ACT-XT  MAX-SCREENS CELLS ALLOT    \ per-screen activate xt (0=none)

\ In REGISTER-SCREEN, after the SCR-KEY-XT init line:
    0 R@ CELLS SCR-ACT-XT + !

\ New registration word (mirrors SET-SCREEN-KEYS):
: SET-SCREEN-ACT  ( xt screen-id -- )
    CELLS SCR-ACT-XT + ! ;

\ Replace DO-SELECT:
: DO-SELECT  ( -- )
    SCREEN-ID @ 1- CELLS SCR-ACT-XT + @ DUP 0<> IF
        EXECUTE
    ELSE
        DROP
        SCREEN-ID @ 7 = IF SCR-SEL @ SHOW-NTH-DOC THEN   \ legacy fallback
    THEN ;
```

**Impact:** ~8 lines changed/added. No existing behaviour changes (Docs
screen would register its handler via `SET-SCREEN-ACT` or keep the
fallback). All other screens gain Enter-activation for free.

---

## 2. Line-Input Widget (`W.INPUT`)

**Problem:** The SDL widget vocabulary has no text-input primitive. Apps
that need user text entry (compose a post, enter a search query) must
roll their own KEY loop and cursor management, duplicating effort and
looking inconsistent with the rest of the TUI.

**Proposed addition (§9.5 SDL):**

```forth
\ W.INPUT ( buf maxlen prompt-addr prompt-len -- actual-len )
\   Display prompt, read a line of text into buf (max maxlen chars).
\   Handles printable chars, Backspace (8/127), Enter (13) to confirm,
\   Escape (27) to cancel (returns 0). Echoes to screen in-place.

: TUI-INPUT  ( buf maxlen prompt-addr prompt-len -- actual-len )
    TYPE                                \ print prompt
    0                                   ( buf maxlen pos )
    BEGIN
        KEY                             ( buf maxlen pos c )
        DUP 13 = IF DROP NIP NIP EXIT THEN          \ Enter → done
        DUP 27 = IF 2DROP 2DROP 0 EXIT THEN          \ Esc → cancel
        DUP 8 = OVER 127 = OR IF                     \ Backspace
            DROP
            DUP 0> IF
                1-  8 EMIT 32 EMIT 8 EMIT            \ erase char
            THEN
        ELSE                                          \ printable
            2 PICK 2 PICK > IF                        \ pos < maxlen?
                DUP EMIT                              ( buf maxlen pos c )
                3 PICK 2 PICK + C!                    \ buf[pos] = c
                1+
            ELSE DROP THEN
        THEN
    AGAIN ;

\ Vector + public API:
' TUI-INPUT  14 WV!          \ WV slot 14 (extend WVEC-SIZE to 15)
: W.INPUT  ( buf maxlen prompt-addr prompt-len -- len )
    14 WV@ EXECUTE ;
```

**Impact:** ~25 lines added. `WVEC-SIZE` changes from 14 to 15.
No existing words affected. Adds one new public widget `W.INPUT`.

---

## 3. Per-Screen Key Priority (`HANDLE-KEY`)

**Problem:** Per-screen key handlers registered via `SET-SCREEN-KEYS` are
called *last* in `HANDLE-KEY`, after all global bindings are tested. This
means apps can never intercept `r` (refresh), `n`/`p` (select), `[`/`]`
(subscreen), `A` (auto-refresh), `q` (quit), or Enter/Space — the keys
most natural for in-screen actions like reply, repost, or compose.

**Proposed change (§9 HANDLE-KEY):** Call the per-screen handler *first*;
use a non-zero return value to signal "consumed" (skip global handling).

```forth
\ New per-screen key dispatch (returns consumed flag):
: CALL-SCREEN-KEY  ( c -- c consumed )
    SCREEN-ID @ 1- CELLS SCR-KEY-XT + @ DUP 0<> IF
        OVER SWAP EXECUTE   \ xt receives char, leaves consumed flag
    ELSE
        DROP 0              \ no handler → not consumed
    THEN ;

\ HANDLE-KEY — per-screen check moved to top:
: HANDLE-KEY  ( c -- )
    CALL-SCREEN-KEY IF DROP EXIT THEN   \ app consumed it
    \ ... rest of global key dispatch unchanged ...
    DROP ;
```

Existing per-screen handlers (e.g. `TASK-KEYS`) currently consume the
char and leave nothing — they'd need updating to leave a consumed flag:

```forth
\ Old style (still valid if it drops unrecognised keys):
: TASK-KEYS  ( c -- consumed )
    DUP 107 = IF ... 1 EXIT THEN   \ 'k' = kill, consumed
    DUP 115 = IF ... 1 EXIT THEN   \ 's' = restart, consumed
    DROP 0 ;                        \ not consumed → global handles it
```

**Impact:** ~5 lines changed in `HANDLE-KEY`. Existing `TASK-KEYS` needs a
one-line signature change (add `0` or `1` return). Any keys the per-screen
handler returns `0` for fall through to global handling unchanged, so
`n`/`p` navigation still works on screens that don't override it.

---

## Summary

| # | Change | Lines | Breaks existing? |
|---|--------|------:|:---:|
| 1 | `SCR-ACT-XT` | ~8 | No |
| 2 | `W.INPUT` | ~25 | No |
| 3 | `HANDLE-KEY` priority + `CALL-SCREEN-KEY` | ~5 (+1 per existing handler) | Only `TASK-KEYS` needs a return-flag added |

All three are low-risk. The Bluesky TUI can ship without them (using
letter-key actions and a local KEY loop for text), but they'd benefit any
future app screen and make the extension API much more capable.
