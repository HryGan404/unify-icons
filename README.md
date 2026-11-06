# unify-icons

```sh
chmod +x unify-icons.sh
./unify-icons.sh
```

Reload the shell with `Alt+F2` → `r` → `Enter`.

```
--list      list the entries that would be processed, change nothing
--revert    restore Yaru and remove the generated theme and launchers
```

Requires `python3-gi` and `python3-pil`.

---

## What the script does

1. Scans `.desktop` files in these directories, deduplicating by filename and
   skipping `NoDisplay` and `Hidden`:
   
   ```
   ~/.local/share/applications
   /usr/share/applications
   /var/lib/snapd/desktop/applications
   /var/lib/flatpak/exports/share/applications
   ```

2. Takes each entry's `Icon=` value and resolves it to a PNG or SVG through the
   system icon theme (Yaru).

3. For each icon: crop to the `alpha > 128` bounding box, scale the long side to
   87.3% of the canvas, centre it, and composite a drop shadow underneath.

4. Writes to `~/.local/share/icons/Uniform95-Shadow/scalable/<context>/` and
   generates `index.theme`.

5. For entries whose `Icon=` is an absolute path, also writes a same-named
   `.desktop` to `~/.local/share/applications/`, with `Icon=` replaced by a bare
   name and an `X-Unify-Original-Icon=` line holding the original path.

6. Runs `gsettings set org.gnome.desktop.interface icon-theme Uniform95-Shadow`.

`--revert` undoes it: switches back to Yaru, deletes the `.desktop` files
carrying an `X-Unify-Original-Icon=` marker, deletes the theme directory.

---

## Geometry

Canvas 512×512. The body occupies 87.3% of it. The shadow extends a further
4.46% on each side, measured against the body, bringing the total to 95% and
leaving a 2.5% margin on each edge.

Shadow: Gaussian blur with `sigma = 9`, peak alpha 46, vertical offset 2px.
Values sampled from the stock Yaru icon `org.gnome.Calculator`.

The script targets the default Ubuntu Yaru desktop: the shadow parameters come
from Yaru, and both `Inherits=` and `--revert` point at Yaru. Icons are still
generated on Adwaita and other themes, but the shadow style will not match.

`Size=` in `index.theme` equals the actual PNG dimensions (512).

---

## Output

```
~/.local/share/icons/Uniform95-Shadow/
├── index.theme
└── scalable/
    ├── apps/
    ├── mimetypes/
    ├── categories/
    ├── devices/
    └── status/
```

`Inherits=Yaru`, so anything not processed (folders, cursors, panel icons)
still comes from Yaru.

An icon name shared by several launchers is written once. Icons reached by
absolute path are named after the desktop id.

---

## Changing the parameters

Edit the top of the script:

```python
CANVAS = 512      # output size
FILL = 0.95       # visible extent as a fraction of the canvas;
                  # 0.95 leaves 2.5% on each side
```

Re-run `./unify-icons.sh` afterwards.
