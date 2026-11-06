#!/bin/sh
# unify-icons.sh -- make GNOME application icons look the same size.
#
# Single file, no bundled assets. The theme is generated on the spot from the
# icons already installed on this machine, then activated.
#
#   ./unify-icons.sh          build and activate
#   ./unify-icons.sh --list   show what would be processed, change nothing
#   ./unify-icons.sh --revert restore the stock theme
#
# Requires python3 with gi and PIL (python3-gi, python3-pil), which a normal
# GNOME desktop already has. Nothing is written outside ~/.local/share.
set -e

# Pick an interpreter that can actually import what we need. A conda or pyenv
# python3 earlier in PATH usually lacks PyGObject, and failing on a bare
# "python3" would be a confusing way to start.
PY=
for candidate in python3 /usr/bin/python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       "$candidate" -c 'import gi, PIL' >/dev/null 2>&1; then
        PY=$candidate
        break
    fi
done

if [ -z "$PY" ]; then
    echo "no python3 with gi and PIL found" >&2
    echo "install them with: sudo apt install python3-gi python3-pil" >&2
    exit 1
fi

exec "$PY" - "$@" <<'PYTHON'
"""unify-icons.sh -- make GNOME application icons look the same size.

  ./unify-icons.sh          build the theme and activate it
  ./unify-icons.sh --list   list the entries that would be processed
  ./unify-icons.sh --revert restore Yaru and remove generated files
"""
import glob
import io
import os
import subprocess
import sys

THEME = "Uniform95-Shadow"
CANVAS = 512          # output size of every icon, in pixels

# --- the geometry rule -------------------------------------------------------
# The visible extent of an icon is its body plus its drop shadow, and that
# combined extent occupies FILL of the canvas. The shadow reaches out by SPREAD
# on every side, so the body itself has to be a little smaller than FILL:
#
#     body = FILL / (1 + 2 * SPREAD)
#     shadow extent = body * (1 + 2 * SPREAD) = FILL
#
# Yaru draws its shadow by baking black, low-alpha pixels into the PNG alpha
# channel, so an icon that ships with one has a larger alpha bbox than an icon
# that does not. Measuring the alpha bbox therefore compares shadow extents,
# not body sizes -- which is exactly the inconsistency this script removes.
FILL = 0.95           # 0.95 => 2.5% margin on each side
YARU_SOLID = 0.875    # body of a stock Yaru icon, as a fraction of the canvas
YARU_SHADOW = 0.953   # body plus its shadow, same measure
SPREAD = (YARU_SHADOW - YARU_SOLID) / YARU_SOLID / 2   # ~0.0446 per side

# --- the shadow rule ---------------------------------------------------------
# Sampled from a stock Yaru icon at 512px: the gradient runs 18px, the peak is
# alpha 46, and the lower edge is slightly heavier. Sigma 9 reproduces that
# 1%-to-99% transition; it scales linearly with the canvas.
BODY_ALPHA = 128      # alpha above which a pixel counts as body, not shadow
SHADOW_PEAK = 46      # alpha of the halo where fully developed
SHADOW_SIGMA = 9.0
SHADOW_DY = 2         # downward offset, in pixels at 512

# Alpha 128 rather than 200: some icons are tinted plates whose fill is itself
# only ~190 opaque. Treating those as shadow would punch a hole in the plate.
# Real shadows peak far lower (46 on Yaru, under 150 even on the heaviest).

DESKTOP_DIRS = [
    os.path.expanduser("~/.local/share/applications"),
    "/usr/share/applications",
    "/var/lib/snapd/desktop/applications",
    "/var/lib/flatpak/exports/share/applications",
]

ICON_DIRS = [
    os.path.expanduser("~/.local/share/icons"),
    os.path.expanduser("~/.icons"),
    "/usr/share/icons",
    "/usr/share/pixmaps",
    "/usr/local/share/icons",
    "/var/lib/flatpak/exports/share/icons",
    "/var/lib/snapd/desktop/icons",
]


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def load_modules():
    try:
        from PIL import Image, ImageFilter
    except ImportError:
        fail("python3-pil is required (sudo apt install python3-pil)")
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        gi.require_version("GdkPixbuf", "2.0")
        from gi.repository import GdkPixbuf, Gtk
    except (ImportError, ValueError):
        fail("python3-gi is required (sudo apt install python3-gi)")
    return Image, ImageFilter, GdkPixbuf, Gtk


# --- discovering what to convert ---------------------------------------------

def desktop_entries():
    """Every launchable application, as (desktop id, path, icon), deduplicated.

    GNOME identifies a desktop file by its filename, so a user-level copy only
    replaces the system one when the two names match. Deduplicating by id here
    mirrors what the shell does, and keeps the list free of double entries.

    A user-level entry that this script itself wrote in an earlier run carries
    the bare themed name instead of the absolute path it replaced. Reading that
    back would make the second run unable to find its own source, so the icon
    field is rewritten to the original absolute path when one is recorded.
    """
    seen = {}
    shadowed = {}
    for directory in DESKTOP_DIRS:
        if not os.path.isdir(directory):
            continue
        for path in sorted(glob.glob(os.path.join(directory, "*.desktop"))):
            ident = os.path.basename(path)[:-len(".desktop")]
            if ident in seen:
                # Remember the entry this one shadows, so a user-level override
                # that has lost its original Icon= can still be traced back.
                shadowed.setdefault(ident, path)
                continue
            fields = parse_desktop(path)
            # Hidden=true is a tombstone: it exists to mask the entry of the same
            # name found lower in the search path. Recording it as seen stops
            # that entry from being re-added, and there is nothing to convert.
            if fields and fields.get("Hidden", "false").lower() == "true":
                seen[ident] = (path, "")
                continue
            if not fields or fields.get("Type", "Application") != "Application":
                continue
            if fields.get("NoDisplay", "false").lower() == "true":
                continue
            icon = fields.get("Icon", "").strip()
            original = fields.get("X-Unify-Original-Icon", "").strip()
            if original and not icon.startswith("/"):
                icon = original
            seen[ident] = (path, icon)

    # An override written before X-Unify-Original-Icon existed carries only the
    # bare themed name, which no longer resolves once the theme is replaced.
    # Fall back to whatever the system entry said.
    for ident, (path, icon) in list(seen.items()):
        if not icon or icon.startswith("/") or ICON_THEME is None:
            continue
        if ICON_THEME.lookup_icon(icon, CANVAS, 0) is not None:
            continue
        below = shadowed.get(ident)
        if below:
            fields = parse_desktop(below)
            real = (fields or {}).get("Icon", "").strip()
            if real:
                seen[ident] = (path, real)

    return [(i, p, icon) for i, (p, icon) in sorted(seen.items()) if icon]


def parse_desktop(path):
    """Read the [Desktop Entry] group, following the spec closely enough."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    fields, group = {}, None
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            group = line[1:-1]
            continue
        if group != "Desktop Entry" or "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def resolve(name, Gtk, GdkPixbuf, Image, absolute):
    """Load one icon at canvas size, returning (image, source path) or None."""
    if absolute:
        if not os.path.exists(name):
            return None
        try:
            if name.lower().endswith(".svg"):
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                    name, CANVAS, CANVAS, True)
            else:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_size(
                    name, CANVAS, CANVAS)
            data = pixbuf.save_to_bufferv("png", [], [])[1]
            return Image.open(io.BytesIO(data)).convert("RGBA"), name
        except Exception:
            return None

    info = ICON_THEME.lookup_icon(name, CANVAS, 0)
    if info is None:
        return None
    try:
        data = info.load_icon().save_to_bufferv("png", [], [])[1]
        return Image.open(io.BytesIO(data)).convert("RGBA"), info.get_filename()
    except Exception:
        return None


# --- the transform ------------------------------------------------------------

def body_mask(image, Image):
    return image.split()[3].point(lambda v: 255 if v > BODY_ALPHA else 0)


def body_crop(image, Image):
    """Crop to the body, discarding the ring of baked-in shadow."""
    bbox = body_mask(image, Image).getbbox()
    if bbox is None:
        return None
    return image.crop(bbox)


def place(art, fill, Image):
    """Centre art on a square canvas so its longer side is `fill` wide."""
    scale = (CANVAS * fill) / max(art.size)
    size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
    art = art.resize(size, Image.LANCZOS)
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.alpha_composite(art, ((CANVAS - size[0]) // 2, (CANVAS - size[1]) // 2))
    return out


def add_shadow(image, Image, ImageFilter):
    """Composite a synthetic Yaru-style halo underneath the image."""
    sigma = SHADOW_SIGMA * (CANVAS / 512.0)
    halo = body_mask(image, Image).filter(ImageFilter.GaussianBlur(sigma))
    # Blur leaves ~50% coverage along the body edge, so double before scaling to
    # the peak; normalising the plateau instead would stretch the tail ~2x.
    halo = halo.point(lambda v: min(255, v * 2 * SHADOW_PEAK // 255))
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow.putalpha(halo)
    shift = int(round(SHADOW_DY * (CANVAS / 512.0)))
    if shift:
        moved = Image.new("RGBA", image.size, (0, 0, 0, 0))
        moved.paste(shadow, (0, shift))
        shadow = moved
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.alpha_composite(shadow)
    out.alpha_composite(image)
    return out


def convert(image, Image, ImageFilter):
    body = body_crop(image, Image)
    if body is None:
        return None
    target = FILL / (1.0 + 2.0 * SPREAD)
    return add_shadow(place(body, target, Image), Image, ImageFilter)


# --- install ------------------------------------------------------------------

def theme_root():
    return os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "icons", THEME)


def write_index(path):
    groups = {
        "apps": "Applications",
        "categories": "Categories",
        "devices": "Devices",
        "mimetypes": "MimeTypes",
        "status": "Status",
    }
    present = [g for g in groups if os.path.isdir(os.path.join(path, "scalable", g))]
    lines = [
        "[Icon Theme]",
        "Name=" + THEME,
        "Comment=Application icons re-framed to a uniform visible size",
        "Inherits=Yaru",
        "Directories=" + ",".join("scalable/" + g for g in present),
        "",
    ]
    for group in present:
        lines += [
            "[scalable/%s]" % group,
            # Size must equal the actual PNG dimensions. GTK treats a scalable
            # directory as one image to be rescaled and derives the factor from
            # Size; declaring 128 while shipping 512px files makes every lookup
            # hand back artwork 4x the requested size.
            "Size=%d" % CANVAS,
            "MinSize=8",
            "MaxSize=%d" % CANVAS,
            "Type=Scalable",
            "Context=" + groups[group],
            "",
        ]
    with open(os.path.join(path, "index.theme"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def main():
    global ICON_THEME

    args = sys.argv[1:]

    # Anything not recognised has to stop the run. Falling through to the
    # install branch on a typo would silently rebuild the theme.
    unknown = [a for a in args if a not in ("--list", "--revert", "--help")]
    if unknown:
        fail("unknown option: %s\n  --list    list the entries that would be processed\n"
             "  --revert  restore Yaru and remove generated files" % unknown[0])
    if "--help" in args:
        print(__doc__)
        return

    Image, ImageFilter, GdkPixbuf, Gtk = load_modules()

    if "--revert" in args:
        subprocess.run(["gsettings", "set",
                        "org.gnome.desktop.interface", "icon-theme", "Yaru"],
                       check=False)
        # Remove only the launchers this script created, identified by the
        # marker it always writes. Matching on "Icon= is absolute" would miss
        # the ones whose original path is now a bare themed name.
        apps = os.path.expanduser("~/.local/share/applications")
        removed = 0
        for path in glob.glob(os.path.join(apps, "*.desktop")):
            fields = parse_desktop(path) or {}
            if "X-Unify-Original-Icon" not in fields:
                continue
            try:
                os.remove(path)
                removed += 1
            except OSError:
                pass
        root = theme_root()
        if os.path.isdir(root):
            import shutil
            shutil.rmtree(root)
        print("reverted to Yaru (%d launcher%s restored)"
              % (removed, "" if removed == 1 else "s"))
        return

    ICON_THEME = Gtk.IconTheme.new()
    ICON_THEME.set_search_path(ICON_DIRS)
    ICON_THEME.set_custom_theme("Yaru")

    entries = desktop_entries()
    if not entries:
        fail("no applications found; is this a GNOME desktop?")

    if "--list" in args:
        for ident, path, icon in entries:
            absolute = icon.startswith("/")
            src = resolve(icon, Gtk, GdkPixbuf, Image, absolute)
            state = "ok" if src else "unresolved"
            print("%-40s %-10s %s" % (ident, state, icon))
        return

    root = theme_root()
    if os.path.isdir(root):
        import shutil
        shutil.rmtree(root)

    overrides = os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "applications")

    made, unresolved, overridden = 0, [], []
    written = {}   # output path -> desktop id that produced it

    for ident, path, icon in entries:
        absolute = icon.startswith("/")
        loaded = resolve(icon, Gtk, GdkPixbuf, Image, absolute)
        if loaded is None:
            unresolved.append(ident)
            continue
        image, source = loaded
        framed = convert(image, Image, ImageFilter)
        if framed is None:
            unresolved.append(ident)
            continue

        # An absolute Icon= bypasses the theme system entirely, so the icon is
        # stored under the desktop id and a user-level .desktop re-points at it.
        name = ident if absolute else icon
        group = "apps"
        parent = os.path.basename(os.path.dirname(source or ""))
        if parent in ("mimetypes", "devices", "status", "categories"):
            group = parent

        target = os.path.join(root, "scalable", group, name + ".png")
        # Several launchers can share one icon name. Writing them all is wasted
        # work and would double-count the summary, so the first one wins.
        if target in written:
            continue

        os.makedirs(os.path.dirname(target), exist_ok=True)
        framed.save(target)
        written[target] = ident
        made += 1

        if absolute:
            # `icon` is already the original absolute path, either read straight
            # from the system entry or recovered from X-Unify-Original-Icon.
            # Recording it here rather than re-reading the Icon= line later is
            # what stops the marker from degrading to a bare name on re-runs.
            overridden.append((ident, name, path, icon))

    if made == 0:
        fail("nothing could be converted; are any icons installed?")

    write_index(root)

    # Overrides keep the filename of the entry they replace, because GNOME
    # identifies desktop files by filename: a differently named copy is not a
    # replacement but an additional launcher.
    #
    # The original Icon= value is recorded in X-Unify-Original-Icon so a later
    # run can still find the source artwork. Without it the second run would
    # read back its own override, see a bare name that only exists inside the
    # theme it is about to delete, and skip the icon as unresolvable.
    os.makedirs(overrides, exist_ok=True)
    for ident, name, src, original in overridden:
        try:
            with open(src, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        # Drop a previous marker, then swap the Icon= line for the themed name
        # and record the original path that was resolved earlier.
        out, replaced = [], False
        for line in text.splitlines():
            if line.startswith("X-Unify-Original-Icon="):
                continue
            if not replaced and line.startswith("Icon="):
                out.append("Icon=" + name)
                out.append("X-Unify-Original-Icon=" + original)
                replaced = True
            else:
                out.append(line)
        if not replaced:
            continue
        with open(os.path.join(overrides, ident + ".desktop"),
                  "w", encoding="utf-8") as fh:
            fh.write("\n".join(out) + "\n")

    subprocess.run(["gsettings", "set",
                    "org.gnome.desktop.interface", "icon-theme", THEME],
                   check=False)

    print("theme      " + root)
    print("icons      %d converted" % made)
    if overridden:
        print("overrides  %d launcher%s re-pointed" %
              (len(overridden), "" if len(overridden) == 1 else "s"))
    if unresolved:
        print("skipped    %d without usable artwork: %s"
              % (len(unresolved), ", ".join(unresolved[:5])))
    print()
    print("activate with: Alt+F2, r, Enter")


ICON_THEME = None

main()
PYTHON