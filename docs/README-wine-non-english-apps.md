# Running non-English Windows apps in the Wine32 sandbox on NetBSD

This covers two separate problems that show up when running old
non-English (Russian, in these examples) Windows apps under Wine in the
i386 sandbox:

1. Text showing as `?????` instead of the right characters (codepage)
2. Needing to type in the app's language, which needs a matching
   keyboard layout

Both apply inside the wine32 sandbox described in the main
`README.md` / `wine32-sandbox.sh`.

---

## Part 1 — Fixing the codepage (garbled text / `?????`)

### How to tell if this is your problem

- Text shows up as literal `?` characters → codepage mismatch (this
  section)
- Text shows up as boxes/tofu (`▯▯▯`) → missing font glyphs, a
  different problem, not covered here

Wine has no persistent "Language for non-Unicode programs" control
panel the way real Windows does. Instead, it reads your Unix locale
(`LC_ALL`) each time it starts and derives the matching Windows
codepage from it. So the fix is to run Wine with the right locale set.

### 1.1 Find available locales for your target language

Inside the sandbox, as the `wine` user:

```sh
locale -a | grep -i ru
```

Example output:

```
ru
ru_BY.CP1251
ru_BY.UTF-8
ru_RU.CP1251
ru_RU.CP866
ru_RU.ISO8859-5
ru_RU.KOI8-R
ru_RU.UTF-8
```

Replace `ru` with the relevant language prefix for other languages
(`de` for German, `fr` for French, `ja` for Japanese, etc).

### 1.2 Run the app with that locale (temporary, one run)

```sh
LC_ALL=ru_RU.CP1251 wine keystrokes.exe
```

The exact locale variant mostly doesn't matter — Wine only reads the
language part (`ru_RU`) to look up the matching Windows codepage
(Cyrillic apps map to ACP 1251 / OEMCP 866 regardless of which
`ru_RU.*` variant you pick). Pick whichever one is listed; if one
doesn't work, try another from the list.

### 1.3 Make it permanent for the wine user

If most of what you run in this sandbox is Russian-language software,
set it once in the wine user's profile so every wine launch picks it
up automatically:

```sh
echo 'LC_ALL=ru_RU.CP1251; export LC_ALL' >> /home/wine/.profile
```

From then on, `su -l wine` sets the locale automatically — just run
`wine program.exe` with no prefix needed.

### 1.4 If you need both English and Russian apps regularly

Don't set `LC_ALL` permanently in that case — leave `.profile` at the
system default and set it per-command instead:

```sh
wine english_app.exe                      # normal default locale
LC_ALL=ru_RU.CP1251 wine russian_app.exe  # only this one run in Russian
```

Or make short shell aliases in `/home/wine/.profile` for convenience:

```sh
alias wine-ru='LC_ALL=ru_RU.CP1251 wine'
```

Then just run `wine-ru russian_app.exe` whenever needed, leaving plain
`wine` at the default locale for everything else.

---

## Part 2 — Keyboard layout switching (typing in the app's language)

Some apps (typing tutors especially) require you to actually type in
the target language, which needs a matching X keyboard layout, not
just the right codepage for display.

### 2.1 Add the layout temporarily, before running the app

```sh
setxkbmap -layout "us,ru" -option "grp:alt_shift_toggle"
```

This adds Russian as a second layout alongside US English, switchable
with Alt+Shift while any window is focused (including inside the
sandboxed Wine app).

Then run the app as usual:

```sh
LC_ALL=ru_RU.CP1251 wine keystrokes.exe
```

### 2.2 Reset back to English-only after you're done

`setxkbmap` affects your whole X session (not just the sandbox), and
does not undo itself — the next call replaces the current config
entirely, so just set it back to a single layout:

```sh
setxkbmap -layout "us"
```

### 2.3 Convenience aliases for switching back and forth

Add to your normal host shell profile (`~/.profile` or `~/.shrc`, not
inside the sandbox — `setxkbmap` is an X client tool that runs on the
host):

```sh
alias kb-en='setxkbmap -layout "us"'
alias kb-ru='setxkbmap -layout "us,ru" -option "grp:alt_shift_toggle"'
```

Usage:

```sh
kb-ru                                     # before a Russian app session
LC_ALL=ru_RU.CP1251 wine keystrokes.exe
kb-en                                     # after, back to English only
```

### 2.4 Check current layout state anytime

```sh
setxkbmap -query
```

### Note on persistence

`setxkbmap` changes are not saved anywhere — they only last for the
current X session and reset to your normal startup default (usually
plain `us`) on reboot or X restart. There is nothing to "undo"
permanently; a fresh session already starts back at English-only.

---

## Quick reference

| Goal | Command |
|---|---|
| List available locales for a language | `locale -a \| grep -i <lang-code>` |
| Run one app in Russian | `LC_ALL=ru_RU.CP1251 wine app.exe` |
| Make Russian the sandbox default | append `LC_ALL=ru_RU.CP1251; export LC_ALL` to `/home/wine/.profile` |
| Add RU layout with Alt+Shift toggle | `setxkbmap -layout "us,ru" -option "grp:alt_shift_toggle"` |
| Reset to English-only layout | `setxkbmap -layout "us"` |
| Check current layout | `setxkbmap -query` |
