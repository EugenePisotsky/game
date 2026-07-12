# Asset catalog workflow

`ground_catalog.source.json` is the reviewed source of truth for Ground
families. Saved-world IDs use source-stable values such as `ground.j6`; labels
and descriptions may improve without breaking maps.

Each item records its source family, collection, role, whether it is safe for
generic stacking, and whether it is enabled for runtime generation. Rotation
files are never listed by hand: the sync tool derives E/N/S/W paths from
`sourceFamily`.

```bash
# Create a draft manifest from the purchased pack (only on a new catalog).
dart run tool/ground_catalog.dart bootstrap

# Apply the reviewed family names, roles, and stacking metadata.
dart run tool/ground_catalog.dart curate

# Check that all source families are described, rotations are complete, IDs
# are unique, and PNG dimensions are valid.
dart run tool/ground_catalog.dart check

# Copy enabled variants and generate the runtime JSON consumed by apps.
dart run tool/ground_catalog.dart sync
```

Generated outputs live under:

- `packages/neura_assets/assets/images/ground/catalog/`
- `packages/neura_assets/assets/catalogs/ground_catalog.json`

Roles currently used by the audit are `base`, `surface`, `overlay`,
`transition`, and `structural`. The editor exposes every valid family for
experimentation and shows its role in the palette. The `stackable` flag records
whether a family is genuinely safe as a generic layer; base replacements,
cliffs, platforms, and raised road blocks will eventually receive dedicated
placement behavior.

`Ground I10` is intentionally disabled: its north file is a nonstandard
overview sheet rather than a fourth rotation.
