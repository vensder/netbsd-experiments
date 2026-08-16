# Building `inputmethod/ibus` on NetBSD when the build fails

`ibus` is in the main pkgsrc tree (not WIP) but frequently isn't
available as a prebuilt binary package. Building it from source on
NetBSD commonly fails with one or both of the errors below. Both are
**confirmed upstream bugs**, not local misconfiguration — this
document records the diagnosis and the fix.

Verified against `ibus-1.5.34nb1` on NetBSD 10.1/11.0, pkgsrc-2026Q2.

---

## Symptom 1: PLIST/pkg_create failure — missing Wayland panel `.desktop` file

```
ERROR: The following files are in the PLIST but not in .../work/.destdir/usr/pkg:
ERROR:   .../share/applications/org.freedesktop.IBus.Panel.Wayland.Gtk3.desktop
```

or, further along:

```
pkg_create: can't stat '.../org.freedesktop.IBus.Panel.Wayland.Gtk3.desktop'
```

### Cause

`ibus` 's `Makefile` auto-detects Wayland platform support via
`devel/wayland/platform.mk` , which returns "yes" for NetBSD whenever
Mesa's EGL support is available — a reasonable general test, but too
coarse for ibus's own `--enable-wayland` build path, which has a gap
on NetBSD: it doesn't actually produce the Wayland panel `.desktop`

file the PLIST expects.

### Fix

Force Wayland support off for this build, via the documented, 
sanctioned override point ( `platform.mk` 's `!defined(...)` guard
exists specifically for this):

```sh
echo 'PLATFORM_SUPPORTS_WAYLAND=no' >> /etc/mk.conf
```

This is a **global** setting — it affects every package that checks
this variable, not just ibus. Given NetBSD's Wayland support is
independently limited anyway (no `libinput` ↔ `wscons` bridge — see
main README), disabling it system-wide on a build machine is
generally the right call, not just a narrow workaround.

---

## Symptom 2: compile failure — `wayland-client.h: No such file or directory`

```
main.c:37:10: fatal error: wayland-client.h: No such file or directory
   37 | #include <wayland-client.h>
```

This appears **after** fixing Symptom 1 above (i.e. once
`--disable-wayland` is correctly passed to `configure` ).

### Cause — confirmed upstream bug

This is a known, acknowledged bug:
[ibus/ibus#2836](https://github.com/ibus/ibus/issues/2836).

`tools/main.vala` has proper `#ifdef IBUS_WAYLAND` guards in its
source. But the **generated** `tools/main.c` (Vala compiles to C, 
and the generated `.c` file is cached/checked into the distribution)
does not get regenerated when Wayland is disabled at configure time —
so a disabled build can still ship with a stale `main.c` that
unconditionally calls real Wayland API functions
( `wl_display_connect` , `wl_registry_add_listener` , etc.), not just an
unused `#include` . Buildlinking the wayland headers is **not**
sufficient by itself, since the generated code contains genuine
Wayland API calls that would need to be linked too — trying to keep
this code path alive only reintroduces the Symptom 1 problem.

ibus's own `Makefile` already has a `pre-build:` target that works
around the identical bug for two other Vala-generated directories
( `ui/gtk3` and `portal` — see
[ibus/ibus#2767](https://github.com/ibus/ibus/issues/2767)), via
`maintainer-clean-generic` , which forces those `.c` files to be
freshly regenerated from `.vala` source at build time instead of
reusing a stale cached copy. As of this writing, that same treatment
has not yet been extended to `tools/` upstream — the ibus maintainer
confirmed (Dec 2025) this is the correct fix and intends to add it, 
but it wasn't in the version tested here.

### Fix — extend the existing `pre-build:` workaround to `tools/`

This mirrors the exact pattern ibus's own Makefile already uses; it's
not a new technique, just applying the maintainer-endorsed fix to a
third directory that needs it.

```sh
cd /usr/pkgsrc/inputmethod/ibus
cp Makefile Makefile.orig    # safety copy before editing
```

Confirm the existing `pre-build:` block:

```sh
grep -n -A5 '^pre-build:' Makefile
```

It should look like:

```makefile
pre-build:
	(cd ${WRKSRC} && ${MAKE_PROGRAM} -C ui/gtk3 maintainer-clean-generic)
	(cd ${WRKSRC} && ${MAKE_PROGRAM} -C portal maintainer-clean-generic)
```

Add a third line for `tools/` , using the identical style. **Recipe
lines under a Makefile target must start with a literal tab
character, not spaces** — edit by hand in `vim` (or your editor of
choice) rather than trust an automated insertion tool blindly; verify
afterward with:

```sh
cat -A Makefile | grep -A6 '^pre-build:'
```

You should see `^I` (tab) at the start of each recipe line. The
finished block should read:

```makefile
pre-build:
	(cd ${WRKSRC} && ${MAKE_PROGRAM} -C ui/gtk3 maintainer-clean-generic)
	(cd ${WRKSRC} && ${MAKE_PROGRAM} -C portal maintainer-clean-generic)
	(cd ${WRKSRC} && ${MAKE_PROGRAM} -C tools maintainer-clean-generic)
```

Clean and rebuild:

```sh
make clean
make bin-install
```

This forces `main.vala` → `main.c` to regenerate fresh at build time, 
correctly respecting the currently-active `--disable-wayland` decision, 
instead of reusing the stale pre-generated file.

---

## Result

A successful build produces and installs a real binary package:

```
=> Creating binary package /usr/pkgsrc/packages/All/ibus-1.5.34nb1.tgz
===> Installing binary package of ibus-1.5.34nb1
```

Once built, this `.tgz` is reusable — copy it (or your whole
`/usr/pkgsrc/packages/All` ) to other NetBSD machines of the same
release/architecture via `pkg_add` , rather than repeating this build
process on every machine that needs `ibus` as a dependency (it's a
common transitive dependency of GTK3/Qt-based desktop packages, 
including Plasma6 and various GUI audio tools).

## Notes for reporting upstream

The `Makefile.orig` diff (adding one `pre-build:` line) is small
enough to be worth submitting as a pkgsrc patch
( `pkgsrc/inputmethod/ibus/patches/` or a follow-up comment on
[ibus/ibus#2836](https://github.com/ibus/ibus/issues/2836)) rather
than keeping it as a purely local fix — the maintainer has already
confirmed this is the intended solution, just not yet applied to
`tools/` in the version packaged here.
