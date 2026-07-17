use clap::{Parser, Subcommand};
use image::{DynamicImage, GenericImage, ImageFormat, RgbaImage, imageops::FilterType};
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fs;
use std::io::{BufReader, Cursor, Read};
use std::path::{Path, PathBuf};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const DIRECTIONS: [&str; 8] = [
    "south",
    "west",
    "east",
    "north",
    "southWest",
    "northWest",
    "southEast",
    "northEast",
];

#[derive(Parser)]
#[command(about = "Import Other Worlds environment assets into Neura")]
struct Cli {
    #[command(subcommand)]
    command: Command,

    /// Repository root. Defaults to the current directory.
    #[arg(long, default_value = ".")]
    root: PathBuf,

    /// Import-rule file relative to the repository root.
    #[arg(long, default_value = "tool/environment_importer/rules.json")]
    rules: PathBuf,
}

#[derive(Subcommand)]
enum Command {
    /// Scan source assets and write the discovered manifest.
    Scan,
    /// Scan, copy runtime assets, make thumbnails, and generate the catalog.
    Build,
    /// Verify that generated files match the source and configuration.
    Check,
    /// Verify only discovered visual assets and their generated catalog/images.
    CheckAssets,
    /// Split the authored environment document into runtime world chunks.
    BuildWorld,
    /// Verify the generated world manifest and chunks.
    CheckWorld,
    /// Erase all authored terrain and objects while preserving the world grid.
    ClearWorld {
        /// Confirm the destructive reset.
        #[arg(long)]
        yes: bool,
    },
    /// Export the authored world and only its referenced images for release.
    ExportWorld,
    /// Verify the self-contained release world and its size budget.
    CheckRelease,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rules {
    schema_version: u32,
    packs: Vec<PackRule>,
    generated_image_root: PathBuf,
    catalog_path: PathBuf,
    manifest_path: PathBuf,
    overrides_path: PathBuf,
    manual_catalog_path: PathBuf,
    geometry_overrides_catalog_path: PathBuf,
    source_world_path: PathBuf,
    world_manifest_path: PathBuf,
    world_chunks_root: PathBuf,
    release_root: PathBuf,
    release_max_bytes: u64,
    world_chunk_size: f64,
    world_width: f64,
    world_height: f64,
    player_spawn: RulePoint,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PackRule {
    id: String,
    display_name: String,
    source_root: PathBuf,
    #[serde(default)]
    release_max_dimension: Option<u32>,
    ground: Option<GroundRule>,
    #[serde(default)]
    objects: Vec<ObjectRule>,
    #[serde(default)]
    deferred: Vec<DeferredRule>,
    #[serde(default)]
    split_incomplete_kinds: BTreeSet<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeferredRule {
    pattern: String,
    reason: String,
}

#[derive(Debug, Deserialize)]
struct RulePoint {
    x: f64,
    y: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroundRule {
    tile_pattern: String,
    decal_pattern: String,
    water_pattern: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObjectRule {
    kind: String,
    #[serde(default)]
    display_name: Option<String>,
    category_path: Vec<String>,
    #[serde(default)]
    source_prefix: Option<String>,
    #[serde(default)]
    pattern: Option<String>,
    #[serde(default)]
    singleton_pattern: Option<String>,
    directionless_pattern: Option<String>,
    allowed_view_counts: Vec<u8>,
    #[serde(default)]
    prefer_directional: bool,
    #[serde(default = "default_rule_render_scale")]
    render_scale: f64,
    #[serde(default = "default_render_band")]
    render_band: String,
    #[serde(default)]
    sort_anchor_x: f64,
    #[serde(default)]
    sort_anchor_y: f64,
    #[serde(default)]
    default_sort_bias: f64,
    #[serde(default = "default_pivot_x")]
    pivot_x: f64,
    #[serde(default = "default_pivot_y")]
    pivot_y: f64,
    #[serde(default)]
    collision_profile: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct SourceImage {
    source: String,
    width: u32,
    height: u32,
    sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct DiscoveredMaterial {
    pack_id: String,
    #[serde(
        default = "default_material_kind",
        skip_serializing_if = "is_ground_material_kind"
    )]
    kind: String,
    number: u32,
    tile: SourceImage,
    #[serde(skip_serializing_if = "Option::is_none")]
    decal: Option<SourceImage>,
}

fn default_material_kind() -> String {
    "ground".into()
}

fn is_ground_material_kind(kind: &String) -> bool {
    kind == "ground"
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct DiscoveredObject {
    pack_id: String,
    kind: String,
    category_path: Vec<String>,
    number: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    source_variant: Option<u8>,
    view_mode: String,
    views: BTreeMap<u8, SourceImage>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct DiscoveredSourceStatus {
    source: String,
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    family: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    asset_number: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    view: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    schema_version: u32,
    packs: Vec<String>,
    materials: Vec<DiscoveredMaterial>,
    objects: Vec<DiscoveredObject>,
    sources: Vec<DiscoveredSourceStatus>,
    warnings: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Overrides {
    #[allow(dead_code)]
    schema_version: Option<u32>,
    #[serde(default)]
    materials: BTreeMap<String, MaterialOverride>,
    #[serde(default)]
    objects: BTreeMap<String, ObjectOverride>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MaterialOverride {
    id: Option<String>,
    name: Option<String>,
    default_radius: Option<f64>,
    repeat_world_width: Option<f64>,
    repeat_world_height: Option<f64>,
    tags: Option<Vec<String>>,
    texture: Option<String>,
    decal: Option<String>,
    #[serde(default)]
    exclude: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObjectOverride {
    id: Option<String>,
    name: Option<String>,
    render_scale: Option<f64>,
    render_band: Option<String>,
    sort_anchor_x: Option<f64>,
    sort_anchor_y: Option<f64>,
    default_sort_bias: Option<f64>,
    pivot_x: Option<f64>,
    pivot_y: Option<f64>,
    collision_profile: Option<String>,
    tags: Option<Vec<String>>,
    category_path: Option<Vec<String>>,
    view_images: Option<BTreeMap<String, String>>,
    #[serde(default)]
    exclude: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Catalog {
    schema_version: u32,
    #[serde(default)]
    source_packs: Vec<CatalogSourcePack>,
    materials: Vec<CatalogMaterial>,
    objects: Vec<CatalogObject>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogSourcePack {
    id: String,
    name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogMaterial {
    id: String,
    name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    source_pack: String,
    texture: String,
    decal: String,
    #[serde(default, skip_serializing_if = "is_zero")]
    texture_logical_width: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    texture_logical_height: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    decal_logical_width: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    decal_logical_height: u32,
    #[serde(default = "default_repeat_world_size")]
    repeat_world_width: f64,
    #[serde(default = "default_repeat_world_size")]
    repeat_world_height: f64,
    default_radius: f64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    thumbnail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogObject {
    id: String,
    name: String,
    category: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    family: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    source_pack: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    category_path: Vec<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    view_mode: String,
    render_scale: f64,
    #[serde(default = "default_render_band")]
    render_band: String,
    #[serde(default)]
    sort_anchor_x: f64,
    #[serde(default)]
    sort_anchor_y: f64,
    #[serde(default)]
    default_sort_bias: f64,
    #[serde(default, skip_serializing_if = "serde_json::Value::is_null")]
    geometry: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    collision_profile: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    thumbnail: Option<String>,
    views: BTreeMap<String, CatalogView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogView {
    image: String,
    #[serde(default, skip_serializing_if = "is_zero")]
    logical_width: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    logical_height: u32,
    #[serde(default = "default_pivot_x")]
    pivot_x: f64,
    #[serde(default = "default_pivot_y")]
    pivot_y: f64,
}

fn is_zero(value: &u32) -> bool {
    *value == 0
}

fn default_pivot_x() -> f64 {
    0.5
}

fn default_rule_render_scale() -> f64 {
    1.0
}

fn default_render_band() -> String {
    "depthSorted".to_owned()
}

fn default_repeat_world_size() -> f64 {
    8.0
}

fn default_pivot_y() -> f64 {
    1.0
}

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let root = cli.root.canonicalize()?;
    let rules: Rules = read_json(&root.join(cli.rules))?;
    if rules.schema_version != 1 {
        return Err(format!("unsupported rules schema {}", rules.schema_version).into());
    }
    validate_rules(&rules)?;

    match cli.command {
        Command::Scan => {
            let manifest = scan(&root, &rules)?;
            write_json(&root.join(&rules.manifest_path), &manifest)?;
            print_summary(&manifest, "scanned");
        }
        Command::Build => {
            let manifest = scan(&root, &rules)?;
            build(&root, &rules, &manifest)?;
            print_summary(&manifest, "built");
        }
        Command::Check => {
            let manifest = scan(&root, &rules)?;
            check(&root, &rules, &manifest)?;
            check_world(&root, &rules)?;
            check_release(&root, &rules)?;
            print_summary(&manifest, "verified");
            println!("  chunked world and release bundle are current");
        }
        Command::CheckAssets => {
            let manifest = scan(&root, &rules)?;
            check(&root, &rules, &manifest)?;
            print_summary(&manifest, "verified");
        }
        Command::BuildWorld => {
            build_world(&root, &rules)?;
            println!("built chunked environment world");
        }
        Command::CheckWorld => {
            check_world(&root, &rules)?;
            println!("verified chunked environment world");
        }
        Command::ClearWorld { yes } => {
            if !yes {
                return Err(
                    "clear-world erases all authored terrain and objects; rerun with --yes".into(),
                );
            }
            clear_world(&root, &rules)?;
            println!("cleared authored environment world");
        }
        Command::ExportWorld => {
            export_world(&root, &rules)?;
            println!("exported self-contained release world");
        }
        Command::CheckRelease => {
            check_release(&root, &rules)?;
            println!("verified self-contained release world");
        }
    }
    Ok(())
}

fn validate_rules(rules: &Rules) -> Result<()> {
    let mut pack_ids = BTreeSet::new();
    for pack in &rules.packs {
        if !pack_ids.insert(pack.id.as_str()) {
            return Err(format!("duplicate source pack id {}", pack.id).into());
        }
        let mut kinds = BTreeSet::new();
        for rule in &pack.objects {
            if !kinds.insert(rule.kind.as_str()) {
                return Err(format!("duplicate family {} in pack {}", rule.kind, pack.id).into());
            }
            if rule.category_path.is_empty() {
                return Err(format!("family {} has an empty category path", rule.kind).into());
            }
            if rule.allowed_view_counts.is_empty()
                || rule
                    .allowed_view_counts
                    .iter()
                    .any(|count| ![1, 4, 8].contains(count))
            {
                return Err(format!(
                    "family {} has unsupported allowed view counts {:?}",
                    rule.kind, rule.allowed_view_counts
                )
                .into());
            }
            directional_pattern(rule)?;
            singleton_pattern(rule)?;
            directionless_pattern(rule)?;
        }
        for kind in &pack.split_incomplete_kinds {
            if !kinds.contains(kind.as_str()) {
                return Err(
                    format!("pack {} splits unknown incomplete family {kind}", pack.id).into(),
                );
            }
        }
    }
    Ok(())
}

fn scan(root: &Path, rules: &Rules) -> Result<Manifest> {
    let mut tiles = BTreeMap::<(usize, u32), SourceImage>::new();
    let mut decals = BTreeMap::<(usize, u32), SourceImage>::new();
    let mut waters = BTreeMap::<(usize, u32), SourceImage>::new();
    let mut grouped = BTreeMap::<(usize, usize, u32), BTreeMap<u8, SourceImage>>::new();
    let mut directionless = BTreeMap::<(usize, usize, u32), SourceImage>::new();
    let mut group_statuses = BTreeMap::<(usize, usize, u32), Vec<usize>>::new();
    let mut directionless_statuses = BTreeMap::<(usize, usize, u32), usize>::new();
    let mut sources = Vec::<DiscoveredSourceStatus>::new();

    for (pack_index, pack) in rules.packs.iter().enumerate() {
        let source_root = root.join(&pack.source_root);
        let ground_regexes = pack
            .ground
            .as_ref()
            .map(|ground| -> Result<(Regex, Regex, Regex)> {
                Ok((
                    Regex::new(&ground.tile_pattern)?,
                    Regex::new(&ground.decal_pattern)?,
                    Regex::new(&ground.water_pattern)?,
                ))
            })
            .transpose()?;
        let object_regexes = pack
            .objects
            .iter()
            .map(|rule| {
                Ok((
                    Regex::new(&directional_pattern(rule)?)?,
                    singleton_pattern(rule)?
                        .map(|pattern| Regex::new(&pattern))
                        .transpose()?,
                    directionless_pattern(rule)?
                        .map(|pattern| Regex::new(&pattern))
                        .transpose()?,
                ))
            })
            .collect::<Result<Vec<_>>>()?;
        let deferred_regexes = pack
            .deferred
            .iter()
            .map(|rule| Ok((Regex::new(&rule.pattern)?, &rule.reason)))
            .collect::<Result<Vec<_>>>()?;

        let mut paths = fs::read_dir(&source_root)?
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|path| {
                path.is_file()
                    && path
                        .extension()
                        .and_then(|extension| extension.to_str())
                        .is_some_and(|extension| extension.eq_ignore_ascii_case("png"))
            })
            .collect::<Vec<_>>();
        paths.sort();

        for path in paths {
            let file_name = path
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or("source filename is not UTF-8")?;
            let source = relative_path(root, &path)?;

            if let Some((tile_regex, decal_regex, water_regex)) = &ground_regexes {
                if let Some(captures) = tile_regex.captures(file_name) {
                    let number = parse_capture(&captures, 1)?;
                    insert_unique_source_image(
                        &mut tiles,
                        (pack_index, number),
                        inspect_image(root, &path)?,
                        file_name,
                    )?;
                    sources.push(classified_source(source, "ground", number, None));
                    continue;
                }
                if let Some(captures) = decal_regex.captures(file_name) {
                    let number = parse_capture(&captures, 1)?;
                    insert_unique_source_image(
                        &mut decals,
                        (pack_index, number),
                        inspect_image(root, &path)?,
                        file_name,
                    )?;
                    sources.push(classified_source(source, "ground", number, None));
                    continue;
                }
                if let Some(captures) = water_regex.captures(file_name) {
                    let number = parse_capture(&captures, 1)?;
                    insert_unique_source_image(
                        &mut waters,
                        (pack_index, number),
                        inspect_image(root, &path)?,
                        file_name,
                    )?;
                    sources.push(classified_source(source, "water", number, None));
                    continue;
                }
            }

            let mut matches = Vec::<(usize, u32, Option<u8>)>::new();
            for (rule_index, (view_regex, singleton_regex, directionless_regex)) in
                object_regexes.iter().enumerate()
            {
                if let Some(captures) = view_regex.captures(file_name) {
                    matches.push((
                        rule_index,
                        parse_capture(&captures, 1)?,
                        Some(parse_capture(&captures, 2)? as u8),
                    ));
                }
                if let Some(captures) = singleton_regex
                    .as_ref()
                    .and_then(|regex| regex.captures(file_name))
                {
                    matches.push((rule_index, 1, Some(parse_capture(&captures, 1)? as u8)));
                }
                if let Some(captures) = directionless_regex
                    .as_ref()
                    .and_then(|regex| regex.captures(file_name))
                {
                    matches.push((rule_index, parse_capture(&captures, 1)?, None));
                }
            }
            if matches.len() > 1 {
                return Err(format!("source {file_name} matches multiple object rules").into());
            }
            if let Some((rule_index, number, view)) = matches.pop() {
                let rule = &pack.objects[rule_index];
                let key = (pack_index, rule_index, number);
                let status_index = sources.len();
                sources.push(classified_source(source, &rule.kind, number, view));
                let image = inspect_image(root, &path)?;
                if let Some(view) = view {
                    let replaced = grouped.entry(key).or_default().insert(view, image);
                    if replaced.is_some() {
                        return Err(format!("duplicate view for {file_name}").into());
                    }
                    group_statuses.entry(key).or_default().push(status_index);
                } else {
                    if directionless.insert(key, image).is_some() {
                        return Err(format!("duplicate directionless asset for {file_name}").into());
                    }
                    directionless_statuses.insert(key, status_index);
                }
                continue;
            }

            if let Some((_, reason)) = deferred_regexes
                .iter()
                .find(|(regex, _)| regex.is_match(file_name))
            {
                sources.push(DiscoveredSourceStatus {
                    source,
                    status: "deferred".into(),
                    family: None,
                    asset_number: None,
                    view: None,
                    reason: Some((*reason).clone()),
                });
            } else {
                sources.push(DiscoveredSourceStatus {
                    source,
                    status: "unclassified".into(),
                    family: None,
                    asset_number: None,
                    view: None,
                    reason: None,
                });
            }
        }
    }

    let material_numbers = tiles
        .keys()
        .chain(decals.keys())
        .copied()
        .collect::<BTreeSet<_>>();
    let mut materials = Vec::new();
    for (pack_index, number) in material_numbers {
        let pack_id = rules.packs[pack_index].id.clone();
        let tile = tiles
            .remove(&(pack_index, number))
            .ok_or_else(|| format!("{pack_id} ground {number} has a decal but no tile"))?;
        let decal = decals
            .remove(&(pack_index, number))
            .ok_or_else(|| format!("{pack_id} ground {number} has a tile but no decal"))?;
        materials.push(DiscoveredMaterial {
            pack_id,
            kind: "ground".into(),
            number,
            tile,
            decal: Some(decal),
        });
    }
    materials.extend(
        waters
            .into_iter()
            .map(|((pack_index, number), tile)| DiscoveredMaterial {
                pack_id: rules.packs[pack_index].id.clone(),
                kind: "water".into(),
                number,
                tile,
                decal: None,
            }),
    );
    materials.sort_by(|left, right| {
        left.pack_id
            .cmp(&right.pack_id)
            .then(left.kind.cmp(&right.kind))
            .then(left.number.cmp(&right.number))
    });

    let mut warnings = Vec::new();
    let mut objects = Vec::new();
    let object_keys = grouped
        .keys()
        .chain(directionless.keys())
        .copied()
        .collect::<BTreeSet<_>>();
    for key @ (pack_index, rule_index, number) in object_keys {
        let pack = &rules.packs[pack_index];
        let rule = &pack.objects[rule_index];
        let views = grouped.remove(&key).unwrap_or_default();
        let fixed = directionless.remove(&key);
        let mut invalid_reason = None;

        if !views.is_empty() && fixed.is_some() && !rule.prefer_directional {
            invalid_reason = Some(format!(
                "{} {} has both directional and directionless sources",
                rule.kind, number
            ));
        }

        if !views.is_empty() && invalid_reason.is_none() {
            match validated_view_count(&rule.kind, number, &rule.allowed_view_counts, &views) {
                Ok(view_count) => {
                    objects.push(DiscoveredObject {
                        pack_id: pack.id.clone(),
                        kind: rule.kind.clone(),
                        category_path: rule.category_path.clone(),
                        number,
                        source_variant: None,
                        view_mode: view_mode_for_count(view_count)?.into(),
                        views,
                    });
                    if fixed.is_some() {
                        let status = directionless_statuses[&key];
                        sources[status].status = "excluded".into();
                        sources[status].reason = Some(
                            "directional views take precedence for this reviewed family".into(),
                        );
                    }
                    continue;
                }
                Err(error) => {
                    if pack.split_incomplete_kinds.contains(&rule.kind) {
                        for (source_variant, image) in views {
                            objects.push(DiscoveredObject {
                                pack_id: pack.id.clone(),
                                kind: rule.kind.clone(),
                                category_path: rule.category_path.clone(),
                                number,
                                source_variant: Some(source_variant),
                                view_mode: "fixed".into(),
                                views: [(1, image)].into_iter().collect(),
                            });
                        }
                        continue;
                    }
                    invalid_reason = Some(error.to_string());
                }
            }
        } else if views.is_empty() && invalid_reason.is_none() {
            if rule.allowed_view_counts.contains(&1) {
                objects.push(DiscoveredObject {
                    pack_id: pack.id.clone(),
                    kind: rule.kind.clone(),
                    category_path: rule.category_path.clone(),
                    number,
                    source_variant: None,
                    view_mode: "fixed".into(),
                    views: [(1, fixed.expect("object key came from directionless map"))]
                        .into_iter()
                        .collect(),
                });
                continue;
            }
            invalid_reason = Some(format!(
                "{} {} does not permit fixed art",
                rule.kind, number
            ));
        }

        let reason = invalid_reason.expect("invalid object has a reason");
        warnings.push(reason.clone());
        for status in group_statuses.get(&key).into_iter().flatten() {
            sources[*status].status = "invalid".into();
            sources[*status].reason = Some(reason.clone());
        }
        if let Some(status) = directionless_statuses.get(&key) {
            sources[*status].status = "invalid".into();
            sources[*status].reason = Some(reason.clone());
        }
    }
    objects.sort_by(|left, right| {
        left.pack_id
            .cmp(&right.pack_id)
            .then(left.kind.cmp(&right.kind))
            .then(left.number.cmp(&right.number))
            .then(left.source_variant.cmp(&right.source_variant))
    });
    sources.sort_by(|left, right| left.source.cmp(&right.source));

    Ok(Manifest {
        schema_version: 2,
        packs: rules.packs.iter().map(|pack| pack.id.clone()).collect(),
        materials,
        objects,
        sources,
        warnings,
    })
}

fn directional_pattern(rule: &ObjectRule) -> Result<String> {
    rule.pattern
        .clone()
        .or_else(|| {
            rule.source_prefix
                .as_ref()
                .map(|prefix| format!(r"^{}(\d+)_0*([1-8])\.png$", regex::escape(prefix)))
        })
        .or_else(|| rule.singleton_pattern.as_ref().map(|_| r"^$".to_owned()))
        .ok_or_else(|| format!("family {} has no source prefix or pattern", rule.kind).into())
}

fn singleton_pattern(rule: &ObjectRule) -> Result<Option<String>> {
    Ok(rule.singleton_pattern.clone())
}

fn directionless_pattern(rule: &ObjectRule) -> Result<Option<String>> {
    if let Some(pattern) = &rule.directionless_pattern {
        return Ok(Some(pattern.clone()));
    }
    if rule.allowed_view_counts.contains(&1) {
        let prefix = rule.source_prefix.as_ref().ok_or_else(|| {
            format!(
                "family {} permits fixed art but has no directionless pattern or source prefix",
                rule.kind
            )
        })?;
        return Ok(Some(format!(r"^{}(\d+)\.png$", regex::escape(prefix))));
    }
    Ok(None)
}

fn classified_source(
    source: String,
    family: &str,
    asset_number: u32,
    view: Option<u8>,
) -> DiscoveredSourceStatus {
    DiscoveredSourceStatus {
        source,
        status: "classified".into(),
        family: Some(family.into()),
        asset_number: Some(asset_number),
        view,
        reason: None,
    }
}

fn insert_unique_source_image<K: Ord>(
    values: &mut BTreeMap<K, SourceImage>,
    key: K,
    image: SourceImage,
    file_name: &str,
) -> Result<()> {
    if values.insert(key, image).is_some() {
        return Err(format!("duplicate source asset for {file_name}").into());
    }
    Ok(())
}

fn build(root: &Path, rules: &Rules, manifest: &Manifest) -> Result<()> {
    let overrides: Overrides = read_json(&root.join(&rules.overrides_path))?;
    let manual: Catalog = read_json(&root.join(&rules.manual_catalog_path))?;
    let catalog = create_catalog(rules, manifest, &overrides, manual)?;
    let generated_root = root.join(&rules.generated_image_root);
    fs::create_dir_all(&generated_root)?;
    let expected_paths = expected_generated_paths(manifest);
    for path in files_recursively(&generated_root)? {
        let relative = path.strip_prefix(&generated_root)?.to_path_buf();
        if !expected_paths.contains(&relative) {
            fs::remove_file(path)?;
        }
    }
    remove_empty_directories(&generated_root)?;

    for material in &manifest.materials {
        copy_if_changed(
            root,
            &material.tile,
            &generated_root.join(material_image_path(material, "tile")),
        )?;
        let decal_path = generated_root.join(material_image_path(material, "decal"));
        if let Some(decal) = &material.decal {
            copy_if_changed(root, decal, &decal_path)?;
        } else {
            make_soft_decal(&root.join(&material.tile.source), &decal_path)?;
        }
        make_thumbnail(
            &root.join(&material.tile.source),
            &generated_root.join(material_thumbnail_path(material)),
            true,
        )?;
    }
    for object in &manifest.objects {
        for (view, image) in &object.views {
            copy_if_changed(
                root,
                image,
                &generated_root.join(object_image_path(object, *view)),
            )?;
        }
        let preview_view = if object.views.contains_key(&7) { 7 } else { 1 };
        let preview = object
            .views
            .get(&preview_view)
            .expect("validated preview view");
        make_thumbnail(
            &root.join(&preview.source),
            &generated_root.join(object_thumbnail_path(object)),
            false,
        )?;
    }

    write_json(&root.join(&rules.manifest_path), manifest)?;
    write_json(&root.join(&rules.catalog_path), &catalog)?;
    Ok(())
}

fn check(root: &Path, rules: &Rules, manifest: &Manifest) -> Result<()> {
    let expected_manifest = serde_json::to_value(manifest)?;
    let actual_manifest: serde_json::Value = read_json(&root.join(&rules.manifest_path))?;
    if actual_manifest != expected_manifest {
        return Err("discovered manifest is stale; run the importer build".into());
    }

    let overrides: Overrides = read_json(&root.join(&rules.overrides_path))?;
    let manual: Catalog = read_json(&root.join(&rules.manual_catalog_path))?;
    let catalog = create_catalog(rules, manifest, &overrides, manual)?;
    validate_geometry_overrides(root, rules, &catalog)?;
    let expected_catalog = serde_json::to_value(catalog)?;
    let actual_catalog: serde_json::Value = read_json(&root.join(&rules.catalog_path))?;
    if actual_catalog != expected_catalog {
        return Err("environment catalog is stale; run the importer build".into());
    }

    let generated_root = root.join(&rules.generated_image_root);
    let actual_paths = files_recursively(&generated_root)?
        .into_iter()
        .map(|path| Ok(path.strip_prefix(&generated_root)?.to_path_buf()))
        .collect::<Result<BTreeSet<_>>>()?;
    let expected_paths = expected_generated_paths(manifest);
    if actual_paths != expected_paths {
        return Err(
            "generated image cache contains missing or stale files; run the importer build".into(),
        );
    }
    for material in &manifest.materials {
        verify_copy(
            &material.tile,
            &generated_root.join(material_image_path(material, "tile")),
        )?;
        let decal_path = generated_root.join(material_image_path(material, "decal"));
        if let Some(decal) = &material.decal {
            verify_copy(decal, &decal_path)?;
        } else {
            verify_soft_decal(&root.join(&material.tile.source), &decal_path)?;
        }
        require_file(&generated_root.join(material_thumbnail_path(material)))?;
    }
    for object in &manifest.objects {
        for (view, image) in &object.views {
            verify_copy(
                image,
                &generated_root.join(object_image_path(object, *view)),
            )?;
        }
        require_file(&generated_root.join(object_thumbnail_path(object)))?;
    }
    Ok(())
}

fn expected_generated_paths(manifest: &Manifest) -> BTreeSet<PathBuf> {
    let mut paths = BTreeSet::new();
    for material in &manifest.materials {
        paths.insert(material_image_path(material, "tile"));
        paths.insert(material_image_path(material, "decal"));
        paths.insert(material_thumbnail_path(material));
    }
    for object in &manifest.objects {
        for view in object.views.keys() {
            paths.insert(object_image_path(object, *view));
        }
        paths.insert(object_thumbnail_path(object));
    }
    paths
}

fn validate_geometry_overrides(root: &Path, rules: &Rules, catalog: &Catalog) -> Result<()> {
    let value: serde_json::Value = read_json(&root.join(&rules.geometry_overrides_catalog_path))?;
    if value["schemaVersion"].as_u64() != Some(1) {
        return Err("geometry override catalog must use schemaVersion 1".into());
    }
    let objects = value["objects"]
        .as_object()
        .ok_or("geometry override catalog objects must be a JSON object")?;
    let known = catalog
        .objects
        .iter()
        .map(|object| object.id.as_str())
        .collect::<BTreeSet<_>>();
    for (asset_id, geometry) in objects {
        if !known.contains(asset_id.as_str()) {
            return Err(format!("geometry override references unknown asset {asset_id}").into());
        }
        let geometry = geometry
            .as_object()
            .ok_or_else(|| format!("geometry override for {asset_id} must be an object"))?;
        if let Some(footprint) = geometry.get("footprint") {
            validate_geometry_shape(asset_id, "footprint", footprint)?;
        }
        for role in ["blocking", "walkable", "selection"] {
            let Some(shapes) = geometry.get(role) else {
                continue;
            };
            for shape in shapes
                .as_array()
                .ok_or_else(|| format!("{asset_id} {role} must be an array"))?
            {
                validate_geometry_shape(asset_id, role, shape)?;
            }
        }
    }
    Ok(())
}

fn validate_geometry_shape(asset_id: &str, role: &str, shape: &serde_json::Value) -> Result<()> {
    let kind = shape["type"]
        .as_str()
        .ok_or_else(|| format!("{asset_id} {role} shape has no type"))?;
    match kind {
        "circle" => {
            geometry_point(shape, "center", asset_id, role)?;
            positive_number(shape, "radius", asset_id, role)?;
        }
        "ellipse" => {
            geometry_point(shape, "center", asset_id, role)?;
            let (x, y) = geometry_point(shape, "radius", asset_id, role)?;
            if x <= 0.0 || y <= 0.0 {
                return Err(format!("{asset_id} {role} ellipse radii must be positive").into());
            }
        }
        "rectangle" => {
            geometry_point(shape, "center", asset_id, role)?;
            let (x, y) = geometry_point(shape, "size", asset_id, role)?;
            if x <= 0.0 || y <= 0.0 {
                return Err(format!("{asset_id} {role} rectangle size must be positive").into());
            }
            if let Some(rotation) = shape.get("rotationDegrees") {
                finite_number(rotation, asset_id, role, "rotationDegrees")?;
            }
        }
        "capsule" => {
            let start = geometry_point(shape, "start", asset_id, role)?;
            let end = geometry_point(shape, "end", asset_id, role)?;
            positive_number(shape, "radius", asset_id, role)?;
            if start == end {
                return Err(format!("{asset_id} {role} capsule has zero length").into());
            }
        }
        "polygon" => {
            let raw_points = shape["points"]
                .as_array()
                .ok_or_else(|| format!("{asset_id} {role} polygon points must be an array"))?;
            let points = raw_points
                .iter()
                .map(|point| geometry_point_value(point, asset_id, role))
                .collect::<Result<Vec<_>>>()?;
            if points.len() < 3 || polygon_area(&points).abs() < 1e-8 {
                return Err(format!("{asset_id} {role} polygon is degenerate").into());
            }
            if polygon_self_intersects(&points) {
                return Err(format!("{asset_id} {role} polygon is self-intersecting").into());
            }
        }
        _ => return Err(format!("{asset_id} {role} has unknown shape type {kind}").into()),
    }
    Ok(())
}

fn geometry_point(
    value: &serde_json::Value,
    key: &str,
    asset_id: &str,
    role: &str,
) -> Result<(f64, f64)> {
    geometry_point_value(&value[key], asset_id, role)
}

fn geometry_point_value(
    value: &serde_json::Value,
    asset_id: &str,
    role: &str,
) -> Result<(f64, f64)> {
    let x = finite_number(&value["x"], asset_id, role, "x")?;
    let y = finite_number(&value["y"], asset_id, role, "y")?;
    Ok((x, y))
}

fn positive_number(
    value: &serde_json::Value,
    key: &str,
    asset_id: &str,
    role: &str,
) -> Result<f64> {
    let number = finite_number(&value[key], asset_id, role, key)?;
    if number <= 0.0 {
        return Err(format!("{asset_id} {role} {key} must be positive").into());
    }
    Ok(number)
}

fn finite_number(
    value: &serde_json::Value,
    asset_id: &str,
    role: &str,
    field: &str,
) -> Result<f64> {
    let number = value
        .as_f64()
        .ok_or_else(|| format!("{asset_id} {role} {field} must be a number"))?;
    if !number.is_finite() {
        return Err(format!("{asset_id} {role} {field} must be finite").into());
    }
    Ok(number)
}

fn polygon_area(points: &[(f64, f64)]) -> f64 {
    (0..points.len())
        .map(|index| {
            let next = (index + 1) % points.len();
            points[index].0 * points[next].1 - points[next].0 * points[index].1
        })
        .sum::<f64>()
        / 2.0
}

fn polygon_self_intersects(points: &[(f64, f64)]) -> bool {
    for first in 0..points.len() {
        let first_next = (first + 1) % points.len();
        for second in (first + 1)..points.len() {
            let second_next = (second + 1) % points.len();
            if first == second
                || first_next == second
                || second_next == first
                || (first == 0 && second_next == 0)
            {
                continue;
            }
            if segments_intersect(
                points[first],
                points[first_next],
                points[second],
                points[second_next],
            ) {
                return true;
            }
        }
    }
    false
}

fn segments_intersect(a: (f64, f64), b: (f64, f64), c: (f64, f64), d: (f64, f64)) -> bool {
    fn cross(a: (f64, f64), b: (f64, f64), c: (f64, f64)) -> f64 {
        (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
    }
    let ab_c = cross(a, b, c);
    let ab_d = cross(a, b, d);
    let cd_a = cross(c, d, a);
    let cd_b = cross(c, d, b);
    ab_c * ab_d < 0.0 && cd_a * cd_b < 0.0
}

#[derive(Default)]
struct GeneratedChunk {
    terrain_strokes: Vec<serde_json::Value>,
    objects: Vec<serde_json::Value>,
    overlap_object_ids: BTreeSet<String>,
}

fn build_world(root: &Path, rules: &Rules) -> Result<()> {
    let (manifest, chunks) = generate_world(root, rules)?;
    write_json(&root.join(&rules.world_manifest_path), &manifest)?;
    let chunks_root = root.join(&rules.world_chunks_root);
    fs::create_dir_all(&chunks_root)?;
    let expected = chunks.keys().cloned().collect::<BTreeSet<_>>();
    for entry in fs::read_dir(&chunks_root)? {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if path.is_file() && name.ends_with(".json") && !expected.contains(name) {
            fs::remove_file(path)?;
        }
    }
    for (name, chunk) in chunks {
        write_json(&chunks_root.join(name), &chunk)?;
    }
    Ok(())
}

fn clear_world(root: &Path, rules: &Rules) -> Result<()> {
    use serde_json::{Value, json};

    let manifest_path = root.join(&rules.world_manifest_path);
    let mut manifest: Value = read_json(&manifest_path)?;
    let world_id = manifest["id"]
        .as_str()
        .ok_or("world manifest has no id")?
        .to_owned();
    let chunk_size = manifest["chunkSize"]
        .as_f64()
        .filter(|value| *value > 0.0)
        .ok_or("world manifest chunkSize must be positive")?;
    let base_material = manifest["baseMaterialId"]
        .as_str()
        .ok_or("world manifest has no baseMaterialId")?
        .to_owned();
    let coordinates = manifest["chunks"]
        .as_array()
        .ok_or("world manifest chunks must be an array")?
        .iter()
        .map(|value| {
            Ok((
                value["x"].as_i64().ok_or("chunk x must be an integer")? as i32,
                value["y"].as_i64().ok_or("chunk y must be an integer")? as i32,
            ))
        })
        .collect::<Result<BTreeSet<_>>>()?;
    let first = coordinates
        .first()
        .copied()
        .ok_or("world manifest has no chunks")?;
    let root_layer = json!({
        "id": "layer_world",
        "name": "World",
        "parentId": null,
        "visible": true,
        "locked": false,
        "exported": true
    });

    manifest["playerSpawn"] = json!({
        "chunk": {"x": first.0, "y": first.1},
        "localPosition": {"x": chunk_size / 2.0, "y": chunk_size / 2.0}
    });
    manifest["travelPoints"] = json!([]);
    manifest["editorLayers"] = json!([root_layer.clone()]);
    manifest["activeLayerId"] = json!("layer_world");

    let chunks_root = root.join(&rules.world_chunks_root);
    fs::create_dir_all(&chunks_root)?;
    let expected = coordinates
        .iter()
        .map(|(x, y)| format!("{x}_{y}.json"))
        .collect::<BTreeSet<_>>();
    for entry in fs::read_dir(&chunks_root)? {
        let path = entry?.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if path.is_file() && name.ends_with(".json") && !expected.contains(name) {
            fs::remove_file(path)?;
        }
    }
    for &(x, y) in &coordinates {
        write_json(
            &chunks_root.join(format!("{x}_{y}.json")),
            &json!({
                "schemaVersion": 1,
                "worldId": world_id.clone(),
                "coordinate": {"x": x, "y": y},
                "size": chunk_size,
                "baseMaterialId": base_material.clone(),
                "terrainStrokes": [],
                "objects": [],
                "overlapObjectIds": []
            }),
        )?;
    }
    write_json(&manifest_path, &manifest)?;

    let source_path = root.join(&rules.source_world_path);
    if source_path.exists() {
        let mut source: Value = read_json(&source_path)?;
        source["width"] = manifest["width"].clone();
        source["height"] = manifest["height"].clone();
        source["baseMaterialId"] = json!(base_material);
        source["terrainStrokes"] = json!([]);
        source["objects"] = json!([]);
        source["editorLayers"] = json!([root_layer]);
        source["activeLayerId"] = json!("layer_world");
        write_json(&source_path, &source)?;
    }
    Ok(())
}

fn check_world(root: &Path, rules: &Rules) -> Result<()> {
    let manifest: serde_json::Value = read_json(&root.join(&rules.world_manifest_path))?;
    let world_id = manifest["id"].as_str().ok_or("world manifest has no id")?;
    let chunk_size = manifest["chunkSize"]
        .as_f64()
        .filter(|value| *value > 0.0)
        .ok_or("world manifest chunkSize must be positive")?;
    let width = manifest["width"]
        .as_f64()
        .filter(|value| *value > 0.0)
        .ok_or("world manifest width must be positive")?;
    let height = manifest["height"]
        .as_f64()
        .filter(|value| *value > 0.0)
        .ok_or("world manifest height must be positive")?;
    let base_material = manifest["baseMaterialId"]
        .as_str()
        .ok_or("world manifest has no baseMaterialId")?;
    let coordinates = manifest["chunks"]
        .as_array()
        .ok_or("world manifest chunks must be an array")?
        .iter()
        .map(|value| {
            Ok((
                value["x"].as_i64().ok_or("chunk x must be an integer")? as i32,
                value["y"].as_i64().ok_or("chunk y must be an integer")? as i32,
            ))
        })
        .collect::<Result<BTreeSet<_>>>()?;
    let columns = (width / chunk_size).ceil() as i32;
    let rows = (height / chunk_size).ceil() as i32;
    let expected_coordinates = (0..rows)
        .flat_map(|y| (0..columns).map(move |x| (x, y)))
        .collect::<BTreeSet<_>>();
    if coordinates != expected_coordinates {
        return Err("world chunks must form a complete rectangular grid".into());
    }

    let spawn_chunk = &manifest["playerSpawn"]["chunk"];
    let spawn = (
        spawn_chunk["x"]
            .as_i64()
            .ok_or("player spawn chunk x must be an integer")? as i32,
        spawn_chunk["y"]
            .as_i64()
            .ok_or("player spawn chunk y must be an integer")? as i32,
    );
    if !coordinates.contains(&spawn) {
        return Err("player spawn must belong to an authored chunk".into());
    }
    let local_spawn = &manifest["playerSpawn"]["localPosition"];
    for axis in ["x", "y"] {
        let value = local_spawn[axis]
            .as_f64()
            .ok_or("player spawn local position must be numeric")?;
        if !(0.0..chunk_size).contains(&value) {
            return Err("player spawn local position must be inside its chunk".into());
        }
    }

    let chunks_root = root.join(&rules.world_chunks_root);
    for &(x, y) in &coordinates {
        let name = format!("{x}_{y}.json");
        let chunk: serde_json::Value = read_json(&chunks_root.join(&name))?;
        if chunk["worldId"].as_str() != Some(world_id)
            || chunk["coordinate"]["x"].as_i64() != Some(x as i64)
            || chunk["coordinate"]["y"].as_i64() != Some(y as i64)
        {
            return Err(format!("environment chunk {name} has the wrong identity").into());
        }
        if chunk["size"].as_f64() != Some(chunk_size)
            || chunk["baseMaterialId"].as_str() != Some(base_material)
        {
            return Err(
                format!("environment chunk {name} disagrees with its world manifest").into(),
            );
        }
    }
    let actual_names = fs::read_dir(&chunks_root)?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| name.ends_with(".json"))
        .collect::<BTreeSet<_>>();
    let expected_names = coordinates
        .iter()
        .map(|(x, y)| format!("{x}_{y}.json"))
        .collect::<BTreeSet<_>>();
    if actual_names != expected_names {
        return Err("world chunk directory contains missing or stale chunk files".into());
    }
    Ok(())
}

struct ReleasePackage {
    files: BTreeMap<String, Vec<u8>>,
}

struct ReleaseImage {
    release_path: String,
    bytes: Vec<u8>,
    source_width: u32,
    source_height: u32,
    output_width: u32,
    output_height: u32,
}

fn export_world(root: &Path, rules: &Rules) -> Result<()> {
    let package = generate_release_package(root, rules)?;
    let release_root = root.join(&rules.release_root);
    fs::create_dir_all(&release_root)?;

    let expected = package.files.keys().cloned().collect::<BTreeSet<_>>();
    for path in files_recursively(&release_root)? {
        let relative = relative_path(&release_root, &path)?;
        if !expected.contains(&relative) {
            fs::remove_file(path)?;
        }
    }
    for (relative, bytes) in package.files {
        let destination = release_root.join(relative);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        if !destination.is_file() || fs::read(&destination)? != bytes {
            fs::write(destination, bytes)?;
        }
    }
    remove_empty_directories(&release_root)?;
    Ok(())
}

fn check_release(root: &Path, rules: &Rules) -> Result<()> {
    let package = generate_release_package(root, rules)?;
    let release_root = root.join(&rules.release_root);
    let actual = files_recursively(&release_root)?
        .into_iter()
        .map(|path| Ok((relative_path(&release_root, &path)?, fs::read(path)?)))
        .collect::<Result<BTreeMap<_, _>>>()?;
    let expected_names = package.files.keys().collect::<BTreeSet<_>>();
    let actual_names = actual.keys().collect::<BTreeSet<_>>();
    if actual_names != expected_names {
        let missing = expected_names.difference(&actual_names).collect::<Vec<_>>();
        let unexpected = actual_names.difference(&expected_names).collect::<Vec<_>>();
        return Err(format!(
            "release bundle file set is stale; missing {missing:?}, unexpected {unexpected:?}; run export-world"
        )
        .into());
    }
    for (relative, expected) in package.files {
        if actual.get(&relative) != Some(&expected) {
            return Err(format!("release file {relative} is stale; run export-world").into());
        }
    }
    Ok(())
}

fn generate_release_package(root: &Path, rules: &Rules) -> Result<ReleasePackage> {
    use serde_json::{Map, Value, json};

    let mut manifest: Value = read_json(&root.join(&rules.world_manifest_path))?;
    let catalog: Value = read_json(&root.join(&rules.catalog_path))?;
    let geometry_overrides: Value = read_json(&root.join(&rules.geometry_overrides_catalog_path))?;
    let world_id = manifest["id"]
        .as_str()
        .ok_or("world manifest has no id")?
        .to_owned();
    let chunk_size = manifest["chunkSize"]
        .as_f64()
        .ok_or("world manifest chunkSize must be numeric")?;
    if chunk_size <= 0.0 {
        return Err("world manifest chunkSize must be positive".into());
    }

    let layer_values = manifest["editorLayers"]
        .as_array()
        .ok_or("world manifest editorLayers must be an array")?;
    let layer_by_id = layer_values
        .iter()
        .map(|layer| {
            let id = layer["id"].as_str().ok_or("editor layer has no id")?;
            Ok((id.to_owned(), layer.clone()))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;
    let mut exported_layers = BTreeSet::new();
    for id in layer_by_id.keys() {
        let mut cursor = Some(id.as_str());
        let mut seen = BTreeSet::new();
        let mut exported = true;
        while let Some(current) = cursor {
            if !seen.insert(current.to_owned()) {
                return Err(format!("editor layer cycle includes {current}").into());
            }
            let layer = layer_by_id
                .get(current)
                .ok_or_else(|| format!("unknown editor layer {current}"))?;
            if layer["exported"].as_bool() == Some(false) {
                exported = false;
                break;
            }
            cursor = layer["parentId"].as_str();
        }
        if exported {
            exported_layers.insert(id.clone());
        }
    }
    if exported_layers.is_empty() {
        return Err("world has no exported editor layer".into());
    }

    let coordinates = manifest["chunks"]
        .as_array()
        .ok_or("world manifest chunks must be an array")?
        .iter()
        .map(|coordinate| {
            Ok((
                coordinate["x"]
                    .as_i64()
                    .ok_or("chunk x must be an integer")? as i32,
                coordinate["y"]
                    .as_i64()
                    .ok_or("chunk y must be an integer")? as i32,
            ))
        })
        .collect::<Result<Vec<_>>>()?;
    let coordinate_set = coordinates.iter().copied().collect::<BTreeSet<_>>();
    if coordinate_set.len() != coordinates.len() {
        return Err("world manifest contains duplicate chunk coordinates".into());
    }

    let mut chunks = BTreeMap::<(i32, i32), Value>::new();
    let mut included_object_ids = BTreeMap::<String, ((i32, i32), String, f64, f64)>::new();
    let mut required_objects = BTreeMap::<String, BTreeSet<String>>::new();
    let mut required_materials = BTreeSet::from([manifest["baseMaterialId"]
        .as_str()
        .ok_or("world manifest has no baseMaterialId")?
        .to_owned()]);
    let mut object_bounds = Vec::<(String, (f64, f64, f64, f64))>::new();

    for &(x, y) in &coordinates {
        let path = root
            .join(&rules.world_chunks_root)
            .join(format!("{x}_{y}.json"));
        let mut chunk: Value = read_json(&path)?;
        if chunk["worldId"].as_str() != Some(world_id.as_str())
            || chunk["coordinate"]["x"].as_i64() != Some(x as i64)
            || chunk["coordinate"]["y"].as_i64() != Some(y as i64)
        {
            return Err(format!("chunk {x}_{y} identity disagrees with its manifest entry").into());
        }
        if chunk["baseMaterialId"].as_str() != manifest["baseMaterialId"].as_str() {
            return Err(format!("chunk {x}_{y} base material disagrees with the world").into());
        }
        let chunk_size = chunk["size"]
            .as_f64()
            .ok_or_else(|| format!("chunk {x}_{y} size is invalid"))?;
        for stroke in chunk["terrainStrokes"].as_array().into_iter().flatten() {
            required_materials.insert(
                stroke["materialId"]
                    .as_str()
                    .ok_or_else(|| format!("chunk {x}_{y} terrain stroke has no materialId"))?
                    .to_owned(),
            );
        }
        let objects = chunk["objects"]
            .as_array_mut()
            .ok_or_else(|| format!("chunk {x}_{y} objects must be an array"))?;
        for object in objects.iter() {
            let object_id = object["id"]
                .as_str()
                .ok_or_else(|| format!("chunk {x}_{y} object has no id"))?;
            let layer_id = object["editorLayerId"]
                .as_str()
                .ok_or_else(|| format!("object {object_id} has no editorLayerId"))?;
            if !layer_by_id.contains_key(layer_id) {
                return Err(
                    format!("object {object_id} references unknown layer {layer_id}").into(),
                );
            }
        }
        objects.retain(|object| {
            object["editorLayerId"]
                .as_str()
                .is_some_and(|id| exported_layers.contains(id))
        });
        for object in objects {
            let object_id = object["id"]
                .as_str()
                .ok_or_else(|| format!("chunk {x}_{y} object has no id"))?;
            let asset_id = object["assetId"]
                .as_str()
                .ok_or_else(|| format!("object {object_id} has no assetId"))?;
            let local_x = object["localPosition"]["x"]
                .as_f64()
                .ok_or_else(|| format!("object {object_id} localPosition.x is invalid"))?;
            let local_y = object["localPosition"]["y"]
                .as_f64()
                .ok_or_else(|| format!("object {object_id} localPosition.y is invalid"))?;
            let world_x = x as f64 * chunk_size + local_x;
            let world_y = y as f64 * chunk_size + local_y;
            if let Some((first_chunk, first_asset, first_x, first_y)) =
                included_object_ids.get(object_id)
            {
                return Err(format!(
                    "duplicate object id `{object_id}`\n  first: chunk {}_{}, asset `{first_asset}`, world position ({first_x:.2}, {first_y:.2})\n  second: chunk {x}_{y}, asset `{asset_id}`, world position ({world_x:.2}, {world_y:.2})\nEach placed object must have a unique world-wide ID. Open Build release in the editor and choose `Repair and continue`, or inspect the two chunk files listed above.",
                    first_chunk.0, first_chunk.1,
                )
                .into());
            }
            included_object_ids.insert(
                object_id.to_owned(),
                ((x, y), asset_id.to_owned(), world_x, world_y),
            );
            let direction = object["direction"].as_str().unwrap_or("south");
            required_objects
                .entry(asset_id.to_owned())
                .or_default()
                .insert(direction.to_owned());
            let bounds = &object["bounds"];
            object_bounds.push((
                object_id.to_owned(),
                (
                    bounds["min"]["x"]
                        .as_f64()
                        .ok_or_else(|| format!("object {object_id} bounds.min.x is invalid"))?,
                    bounds["min"]["y"]
                        .as_f64()
                        .ok_or_else(|| format!("object {object_id} bounds.min.y is invalid"))?,
                    bounds["max"]["x"]
                        .as_f64()
                        .ok_or_else(|| format!("object {object_id} bounds.max.x is invalid"))?,
                    bounds["max"]["y"]
                        .as_f64()
                        .ok_or_else(|| format!("object {object_id} bounds.max.y is invalid"))?,
                ),
            ));
        }
        chunks.insert((x, y), chunk);
    }

    for (&coordinate, chunk) in &mut chunks {
        let overlaps = chunk["overlapObjectIds"].as_array_mut().ok_or_else(|| {
            format!(
                "chunk {}_{} overlapObjectIds must be an array",
                coordinate.0, coordinate.1
            )
        })?;
        overlaps.retain(|id| {
            id.as_str()
                .is_some_and(|id| included_object_ids.contains_key(id))
        });
    }
    for (object_id, bounds) in &object_bounds {
        for &coordinate in &coordinates {
            if bounds_overlap_chunk(*bounds, coordinate, chunk_size) {
                let overlaps = chunks[&coordinate]["overlapObjectIds"]
                    .as_array()
                    .expect("validated overlap array");
                if !overlaps.iter().any(|id| id.as_str() == Some(object_id)) {
                    return Err(format!(
                        "object {object_id} bounds overlap chunk {}_{}, but its overlap index is missing",
                        coordinate.0, coordinate.1
                    )
                    .into());
                }
            }
        }
    }

    let materials_by_id = catalog["materials"]
        .as_array()
        .ok_or("catalog materials must be an array")?
        .iter()
        .map(|material| {
            let id = material["id"]
                .as_str()
                .ok_or("catalog material has no id")?;
            Ok((id.to_owned(), material))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;
    let objects_by_id = catalog["objects"]
        .as_array()
        .ok_or("catalog objects must be an array")?
        .iter()
        .map(|object| {
            let id = object["id"].as_str().ok_or("catalog object has no id")?;
            Ok((id.to_owned(), object))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;
    let source_image_root = rules
        .generated_image_root
        .parent()
        .ok_or("generated image root must have an asset image parent")?;
    let mut images = BTreeMap::<String, ReleaseImage>::new();
    let release_max_dimension_for = |source_pack: &str| {
        rules
            .packs
            .iter()
            .find(|pack| pack.id == source_pack)
            .and_then(|pack| pack.release_max_dimension)
    };

    let mut release_materials = Vec::new();
    for id in &required_materials {
        let source = materials_by_id
            .get(id)
            .ok_or_else(|| format!("world references unknown material {id}"))?;
        let mut material = source
            .as_object()
            .cloned()
            .ok_or("catalog material must be an object")?;
        material.remove("thumbnail");
        let max_dimension = material["sourcePack"]
            .as_str()
            .and_then(release_max_dimension_for);
        for key in ["texture", "decal"] {
            let logical = material[key]
                .as_str()
                .ok_or_else(|| format!("material {id} has no {key} image"))?;
            let release_path = register_release_image(
                root,
                source_image_root,
                logical,
                max_dimension,
                &mut images,
            )?;
            material.insert(key.to_owned(), Value::String(release_path));
        }
        release_materials.push(Value::Object(material));
    }

    let mut release_objects = Vec::new();
    for (id, directions) in &required_objects {
        let source = objects_by_id
            .get(id)
            .ok_or_else(|| format!("world references unknown asset {id}"))?;
        let mut object = source
            .as_object()
            .cloned()
            .ok_or("catalog object must be an object")?;
        object.remove("thumbnail");
        let max_dimension = object["sourcePack"]
            .as_str()
            .and_then(release_max_dimension_for);
        let source_views = object["views"]
            .as_object()
            .ok_or_else(|| format!("asset {id} views must be an object"))?;
        let mut release_views = Map::new();
        for direction in directions {
            let view = source_views
                .get(direction)
                .or_else(|| source_views.get("south"))
                .or_else(|| source_views.values().next())
                .ok_or_else(|| format!("asset {id} has no views"))?;
            let mut release_view = view
                .as_object()
                .cloned()
                .ok_or_else(|| format!("asset {id} view {direction} must be an object"))?;
            let logical = release_view["image"]
                .as_str()
                .ok_or_else(|| format!("asset {id} view {direction} has no image"))?;
            let release_path = register_release_image(
                root,
                source_image_root,
                logical,
                max_dimension,
                &mut images,
            )?;
            release_view.insert("image".to_owned(), Value::String(release_path));
            release_views.insert(direction.clone(), Value::Object(release_view));
        }
        object.insert("views".to_owned(), Value::Object(release_views));
        object.insert("partialViews".to_owned(), Value::Bool(true));
        release_objects.push(Value::Object(object));
    }

    let release_catalog = json!({
        "schemaVersion": catalog["schemaVersion"].clone(),
        "sourcePacks": catalog["sourcePacks"].clone(),
        "materials": release_materials,
        "objects": release_objects
    });
    let override_objects = geometry_overrides["objects"]
        .as_object()
        .ok_or("geometry overrides objects must be an object")?;
    let release_overrides = json!({
        "schemaVersion": 1,
        "objects": override_objects
            .iter()
            .filter(|(id, _)| required_objects.contains_key(*id))
            .map(|(id, geometry)| (id.clone(), geometry.clone()))
            .collect::<Map<_, _>>()
    });

    let release_layers = layer_values
        .iter()
        .filter(|layer| {
            layer["id"]
                .as_str()
                .is_some_and(|id| exported_layers.contains(id))
        })
        .cloned()
        .collect::<Vec<_>>();
    manifest["editorLayers"] = Value::Array(release_layers);
    if !manifest["activeLayerId"]
        .as_str()
        .is_some_and(|id| exported_layers.contains(id))
    {
        manifest["activeLayerId"] = Value::String(
            exported_layers
                .first()
                .expect("validated exported layers")
                .clone(),
        );
    }

    let mut files = BTreeMap::<String, Vec<u8>>::new();
    files.insert("catalog.json".into(), pretty_json_bytes(&release_catalog)?);
    files.insert(
        "geometry_overrides.json".into(),
        pretty_json_bytes(&release_overrides)?,
    );
    files.insert("world.json".into(), pretty_json_bytes(&manifest)?);
    for ((x, y), chunk) in chunks {
        files.insert(format!("chunks/{x}_{y}.json"), pretty_json_bytes(&chunk)?);
    }

    let mut image_report = Vec::new();
    let mut image_bytes = 0_u64;
    for (logical, image) in images {
        image_bytes += image.bytes.len() as u64;
        image_report.push(json!({
            "sourceLogicalPath": logical,
            "releasePath": image.release_path,
            "bytes": image.bytes.len(),
            "sourceWidth": image.source_width,
            "sourceHeight": image.source_height,
            "outputWidth": image.output_width,
            "outputHeight": image.output_height,
            "sha256": sha256_bytes(&image.bytes)
        }));
        files.insert(image.release_path, image.bytes);
    }
    let metadata_bytes = files
        .iter()
        .filter(|(path, _)| !path.starts_with("images/"))
        .map(|(_, bytes)| bytes.len() as u64)
        .sum::<u64>();
    let payload_bytes = image_bytes + metadata_bytes;
    if payload_bytes > rules.release_max_bytes {
        return Err(format!(
            "release payload is {payload_bytes} bytes, exceeding the configured {} byte budget",
            rules.release_max_bytes
        )
        .into());
    }
    let report = json!({
        "schemaVersion": 1,
        "worldId": world_id,
        "chunkCount": coordinates.len(),
        "materialCount": required_materials.len(),
        "objectAssetCount": required_objects.len(),
        "imageCount": image_report.len(),
        "imageBytes": image_bytes,
        "metadataBytes": metadata_bytes,
        "payloadBytes": payload_bytes,
        "sizeLimitBytes": rules.release_max_bytes,
        "images": image_report
    });
    files.insert("asset_report.json".into(), pretty_json_bytes(&report)?);

    let serialized_catalog = String::from_utf8(files["catalog.json"].clone())?;
    for forbidden in [
        "environment_generated/",
        "environment_v2/",
        "content/",
        "packages/",
    ] {
        if serialized_catalog.contains(forbidden) {
            return Err(
                format!("release catalog retains workspace path fragment {forbidden}").into(),
            );
        }
    }
    Ok(ReleasePackage { files })
}

fn register_release_image(
    root: &Path,
    source_image_root: &Path,
    logical: &str,
    maximum_dimension: Option<u32>,
    images: &mut BTreeMap<String, ReleaseImage>,
) -> Result<String> {
    if Path::new(logical).is_absolute() || logical.split('/').any(|component| component == "..") {
        return Err(format!("asset image path is not bundle-relative: {logical}").into());
    }
    if let Some(image) = images.get(logical) {
        return Ok(image.release_path.clone());
    }
    let source = root.join(source_image_root).join(logical);
    require_file(&source).map_err(|_| format!("referenced asset image is missing: {logical}"))?;
    let source_bytes = fs::read(&source)?;
    let (source_width, source_height) = image::image_dimensions(&source)?;
    let largest_dimension = source_width.max(source_height);
    let (bytes, output_width, output_height) = match maximum_dimension
        .filter(|limit| *limit > 0 && largest_dimension > *limit)
    {
        Some(limit) => {
            let resized =
                image::load_from_memory(&source_bytes)?.resize(limit, limit, FilterType::Lanczos3);
            let mut cursor = Cursor::new(Vec::new());
            resized.write_to(&mut cursor, ImageFormat::Png)?;
            (cursor.into_inner(), resized.width(), resized.height())
        }
        None => (source_bytes, source_width, source_height),
    };
    let digest = sha256_bytes(logical.as_bytes());
    let extension = "png";
    let release_path = format!("images/{}.{}", &digest[..20], extension);
    if images
        .values()
        .any(|image| image.release_path == release_path)
    {
        return Err(format!("release image hash collision for {logical}").into());
    }
    images.insert(
        logical.to_owned(),
        ReleaseImage {
            release_path: release_path.clone(),
            bytes,
            source_width,
            source_height,
            output_width,
            output_height,
        },
    );
    Ok(release_path)
}

fn pretty_json_bytes<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec_pretty(value)?;
    bytes.push(b'\n');
    Ok(bytes)
}

fn sha256_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn files_recursively(root: &Path) -> Result<Vec<PathBuf>> {
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    let mut directories = vec![root.to_path_buf()];
    while let Some(directory) = directories.pop() {
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            if path.is_dir() {
                directories.push(path);
            } else if path.is_file() {
                files.push(path);
            }
        }
    }
    files.sort();
    Ok(files)
}

fn remove_empty_directories(root: &Path) -> Result<()> {
    let mut directories = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory)? {
            let path = entry?.path();
            if path.is_dir() {
                pending.push(path.clone());
                directories.push(path);
            }
        }
    }
    directories.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
    for directory in directories {
        if fs::read_dir(&directory)?.next().is_none() {
            fs::remove_dir(directory)?;
        }
    }
    Ok(())
}

fn generate_world(
    root: &Path,
    rules: &Rules,
) -> Result<(serde_json::Value, BTreeMap<String, serde_json::Value>)> {
    use serde_json::{Value, json};
    if rules.world_chunk_size <= 0.0 || rules.world_width <= 0.0 || rules.world_height <= 0.0 {
        return Err("world dimensions and chunk size must be positive".into());
    }
    let source: Value = read_json(&root.join(&rules.source_world_path))?;
    let world_id = source["id"].as_str().ok_or("source world has no id")?;
    let name = source["name"].as_str().ok_or("source world has no name")?;
    let base_material = source["baseMaterialId"]
        .as_str()
        .ok_or("source world has no baseMaterialId")?;
    let columns = (rules.world_width / rules.world_chunk_size).ceil() as i32;
    let rows = (rules.world_height / rules.world_chunk_size).ceil() as i32;
    let coordinates = (0..rows)
        .flat_map(|y| (0..columns).map(move |x| (x, y)))
        .collect::<Vec<_>>();
    let mut chunks = coordinates
        .iter()
        .map(|coordinate| (*coordinate, GeneratedChunk::default()))
        .collect::<BTreeMap<_, _>>();

    for stroke in source["terrainStrokes"].as_array().into_iter().flatten() {
        let radius = stroke["radius"]
            .as_f64()
            .ok_or("stroke radius must be numeric")?;
        let extent = radius
            * (1.0
                + stroke["scatter"].as_f64().unwrap_or(0.0)
                + stroke["sizeJitter"].as_f64().unwrap_or(0.0));
        let points = stroke["points"]
            .as_array()
            .ok_or("stroke points must be an array")?;
        if points.is_empty() {
            continue;
        }
        let xs = points
            .iter()
            .map(|point| -> Result<f64> {
                point["x"]
                    .as_f64()
                    .ok_or_else(|| "stroke x must be numeric".into())
            })
            .collect::<Result<Vec<_>>>()?;
        let ys = points
            .iter()
            .map(|point| -> Result<f64> {
                point["y"]
                    .as_f64()
                    .ok_or_else(|| "stroke y must be numeric".into())
            })
            .collect::<Result<Vec<_>>>()?;
        let min_x = xs.iter().copied().fold(f64::INFINITY, f64::min) - extent;
        let max_x = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max) + extent;
        let min_y = ys.iter().copied().fold(f64::INFINITY, f64::min) - extent;
        let max_y = ys.iter().copied().fold(f64::NEG_INFINITY, f64::max) + extent;
        for &(x, y) in &coordinates {
            if !bounds_overlap_chunk((min_x, min_y, max_x, max_y), (x, y), rules.world_chunk_size) {
                continue;
            }
            let mut local = stroke.clone();
            let local_points = local["points"].as_array_mut().unwrap();
            for point in local_points {
                point["x"] =
                    json!(point["x"].as_f64().unwrap() - x as f64 * rules.world_chunk_size);
                point["y"] =
                    json!(point["y"].as_f64().unwrap() - y as f64 * rules.world_chunk_size);
            }
            chunks.get_mut(&(x, y)).unwrap().terrain_strokes.push(local);
        }
    }

    let catalog: Value = read_json(&root.join(&rules.catalog_path))?;
    let geometry_overrides: Value = read_json(&root.join(&rules.geometry_overrides_catalog_path))?;
    let catalog_objects = catalog["objects"]
        .as_array()
        .ok_or("catalog objects must be an array")?;
    let geometry_by_id = catalog_objects
        .iter()
        .filter_map(|object| {
            let id = object["id"].as_str()?;
            let override_geometry = geometry_overrides["objects"].get(id);
            let geometry = override_geometry.unwrap_or(&object["geometry"]);
            Some((id.to_owned(), geometry.clone()))
        })
        .collect::<BTreeMap<_, _>>();
    let mut object_bounds = Vec::<(String, (f64, f64, f64, f64))>::new();
    for object in source["objects"].as_array().into_iter().flatten() {
        let x = object["x"].as_f64().ok_or("object x must be numeric")?;
        let y = object["y"].as_f64().ok_or("object y must be numeric")?;
        let asset_id = object["assetId"].as_str().ok_or("object has no assetId")?;
        let object_id = object["id"].as_str().ok_or("object has no id")?;
        let radius = geometry_by_id
            .get(asset_id)
            .and_then(|geometry| geometry.get("footprint"))
            .map(shape_bounding_radius)
            .transpose()?
            .unwrap_or(0.5);
        let bounds = (x - radius, y - radius, x + radius, y + radius);
        object_bounds.push((object_id.to_owned(), bounds));
        let owner = (
            (x / rules.world_chunk_size).floor() as i32,
            (y / rules.world_chunk_size).floor() as i32,
        );
        let Some(chunk) = chunks.get_mut(&owner) else {
            continue;
        };
        let mut local = object
            .as_object()
            .cloned()
            .ok_or("object must be a JSON object")?;
        local.remove("x");
        local.remove("y");
        local.insert(
            "localPosition".into(),
            json!({
                "x": x - owner.0 as f64 * rules.world_chunk_size,
                "y": y - owner.1 as f64 * rules.world_chunk_size
            }),
        );
        local.insert(
            "bounds".into(),
            json!({
                "min": {"x": bounds.0, "y": bounds.1},
                "max": {"x": bounds.2, "y": bounds.3}
            }),
        );
        chunk.objects.push(Value::Object(local));
    }
    for (&coordinate, chunk) in &mut chunks {
        for (id, bounds) in &object_bounds {
            if bounds_overlap_chunk(*bounds, coordinate, rules.world_chunk_size) {
                chunk.overlap_object_ids.insert(id.clone());
            }
        }
    }

    let chunk_values = chunks
        .into_iter()
        .map(|((x, y), chunk)| {
            let value = json!({
                "schemaVersion": 1,
                "worldId": world_id,
                "coordinate": {"x": x, "y": y},
                "size": rules.world_chunk_size,
                "baseMaterialId": base_material,
                "terrainStrokes": chunk.terrain_strokes,
                "objects": chunk.objects,
                "overlapObjectIds": chunk.overlap_object_ids
            });
            (format!("{x}_{y}.json"), value)
        })
        .collect::<BTreeMap<_, _>>();
    let spawn_chunk_x = (rules.player_spawn.x / rules.world_chunk_size).floor() as i32;
    let spawn_chunk_y = (rules.player_spawn.y / rules.world_chunk_size).floor() as i32;
    let editor_layers = source["editorLayers"].clone();
    let active_layer_id = source["activeLayerId"].as_str().unwrap_or("layer_world");
    let manifest = json!({
        "schemaVersion": 1,
        "id": world_id,
        "name": name,
        "chunkSize": rules.world_chunk_size,
        "width": rules.world_width,
        "height": rules.world_height,
        "baseMaterialId": base_material,
        "chunks": coordinates.iter().map(|(x, y)| json!({"x": x, "y": y})).collect::<Vec<_>>(),
        "playerSpawn": {
            "chunk": {"x": spawn_chunk_x, "y": spawn_chunk_y},
            "localPosition": {
                "x": rules.player_spawn.x - spawn_chunk_x as f64 * rules.world_chunk_size,
                "y": rules.player_spawn.y - spawn_chunk_y as f64 * rules.world_chunk_size
            }
        },
        "travelPoints": [],
        "editorLayers": editor_layers,
        "activeLayerId": active_layer_id
    });
    Ok((manifest, chunk_values))
}

fn bounds_overlap_chunk(
    bounds: (f64, f64, f64, f64),
    coordinate: (i32, i32),
    chunk_size: f64,
) -> bool {
    let left = coordinate.0 as f64 * chunk_size;
    let top = coordinate.1 as f64 * chunk_size;
    bounds.2 >= left
        && bounds.0 <= left + chunk_size
        && bounds.3 >= top
        && bounds.1 <= top + chunk_size
}

fn shape_bounding_radius(shape: &serde_json::Value) -> Result<f64> {
    let point_radius = |point: &serde_json::Value| -> Result<f64> {
        let x = point["x"].as_f64().ok_or("shape point x must be numeric")?;
        let y = point["y"].as_f64().ok_or("shape point y must be numeric")?;
        Ok((x * x + y * y).sqrt())
    };
    match shape["type"].as_str().unwrap_or("") {
        "circle" => Ok(point_radius(&shape["center"])? + positive_json_number(shape, "radius")?),
        "ellipse" => Ok(point_radius(&shape["center"])?
            + shape["radius"]["x"]
                .as_f64()
                .unwrap_or(0.0)
                .max(shape["radius"]["y"].as_f64().unwrap_or(0.0))),
        "rectangle" => {
            let half_x = shape["size"]["x"].as_f64().unwrap_or(0.0) / 2.0;
            let half_y = shape["size"]["y"].as_f64().unwrap_or(0.0) / 2.0;
            Ok(point_radius(&shape["center"])? + (half_x * half_x + half_y * half_y).sqrt())
        }
        "capsule" => Ok(
            point_radius(&shape["start"])?.max(point_radius(&shape["end"])?)
                + positive_json_number(shape, "radius")?,
        ),
        "polygon" => shape["points"]
            .as_array()
            .ok_or("polygon points must be an array")?
            .iter()
            .map(point_radius)
            .collect::<Result<Vec<_>>>()?
            .into_iter()
            .reduce(f64::max)
            .ok_or_else(|| "polygon has no points".into()),
        kind => Err(format!("unsupported footprint shape {kind}").into()),
    }
}

fn positive_json_number(value: &serde_json::Value, key: &str) -> Result<f64> {
    let number = value[key].as_f64().ok_or("shape value must be numeric")?;
    if number <= 0.0 {
        return Err("shape value must be positive".into());
    }
    Ok(number)
}

fn create_catalog(
    rules: &Rules,
    manifest: &Manifest,
    overrides: &Overrides,
    mut manual: Catalog,
) -> Result<Catalog> {
    let mut materials = Vec::new();
    for material in &manifest.materials {
        let generated_id = format!(
            "{}.{kind}.{:03}",
            material.pack_id,
            material.number,
            kind = material.kind
        );
        let override_value = overrides.materials.get(&generated_id);
        if override_value.is_some_and(|value| value.exclude) {
            continue;
        }
        materials.push(CatalogMaterial {
            id: override_value
                .and_then(|value| value.id.clone())
                .unwrap_or(generated_id),
            name: override_value
                .and_then(|value| value.name.clone())
                .unwrap_or_else(|| {
                    format!("{} {:03}", title_case(&material.kind), material.number)
                }),
            source_pack: material.pack_id.clone(),
            texture: override_value
                .and_then(|value| value.texture.clone())
                .unwrap_or_else(|| {
                    format!(
                        "environment_generated/{}",
                        material_image_path(material, "tile").display()
                    )
                }),
            decal: override_value
                .and_then(|value| value.decal.clone())
                .unwrap_or_else(|| {
                    format!(
                        "environment_generated/{}",
                        material_image_path(material, "decal").display()
                    )
                }),
            texture_logical_width: material.tile.width,
            texture_logical_height: material.tile.height,
            decal_logical_width: material
                .decal
                .as_ref()
                .map_or(material.tile.width, |image| image.width),
            decal_logical_height: material
                .decal
                .as_ref()
                .map_or(material.tile.height, |image| image.height),
            repeat_world_width: override_value
                .and_then(|value| value.repeat_world_width)
                .unwrap_or(material.tile.width as f64 / 64.0),
            repeat_world_height: override_value
                .and_then(|value| value.repeat_world_height)
                .unwrap_or(material.tile.height as f64 / 64.0),
            default_radius: override_value
                .and_then(|value| value.default_radius)
                .unwrap_or(1.8),
            tags: override_value
                .and_then(|value| value.tags.clone())
                .unwrap_or_else(|| {
                    if material.kind == "water" {
                        vec!["water".into(), "non-walkable".into()]
                    } else {
                        Vec::new()
                    }
                }),
            thumbnail: Some(format!(
                "environment_generated/{}",
                material_thumbnail_path(material).display()
            )),
        });
    }
    materials.append(&mut manual.materials);

    let mut objects = Vec::new();
    for object in &manifest.objects {
        let rule = rules
            .packs
            .iter()
            .find(|pack| pack.id == object.pack_id)
            .and_then(|pack| pack.objects.iter().find(|rule| rule.kind == object.kind))
            .ok_or_else(|| format!("missing rule for {} {}", object.pack_id, object.kind))?;
        let generated_id = generated_object_id(object);
        let override_value = overrides.objects.get(&generated_id);
        if override_value.is_some_and(|value| value.exclude) {
            continue;
        }
        let pivot_x = override_value
            .and_then(|value| value.pivot_x)
            .unwrap_or(rule.pivot_x);
        let pivot_y = override_value
            .and_then(|value| value.pivot_y)
            .unwrap_or(rule.pivot_y);
        let views = object
            .views
            .keys()
            .map(|view| {
                let direction = DIRECTIONS
                    .get((*view - 1) as usize)
                    .ok_or_else(|| format!("unsupported direction index {view}"))?;
                Ok((
                    (*direction).to_owned(),
                    CatalogView {
                        image: override_value
                            .and_then(|value| value.view_images.as_ref())
                            .and_then(|images| images.get(*direction))
                            .cloned()
                            .unwrap_or_else(|| {
                                format!(
                                    "environment_generated/{}",
                                    object_image_path(object, *view).display()
                                )
                            }),
                        pivot_x,
                        pivot_y,
                        logical_width: object.views[view].width,
                        logical_height: object.views[view].height,
                    },
                ))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        objects.push(CatalogObject {
            id: override_value
                .and_then(|value| value.id.clone())
                .unwrap_or(generated_id),
            name: override_value
                .and_then(|value| value.name.clone())
                .unwrap_or_else(|| {
                    let base = format!(
                        "{} {:03}",
                        rule.display_name
                            .clone()
                            .unwrap_or_else(|| title_case(&object.kind)),
                        object.number
                    );
                    match object.source_variant {
                        Some(variant) => format!("{base} / Variant {variant}"),
                        None => base,
                    }
                }),
            category: object
                .category_path
                .last()
                .cloned()
                .unwrap_or_else(|| "Uncategorized".into()),
            family: object.kind.clone(),
            source_pack: object.pack_id.clone(),
            category_path: override_value
                .and_then(|value| value.category_path.clone())
                .unwrap_or_else(|| object.category_path.clone()),
            view_mode: object.view_mode.clone(),
            render_scale: override_value
                .and_then(|value| value.render_scale)
                .unwrap_or(rule.render_scale),
            render_band: override_value
                .and_then(|value| value.render_band.clone())
                .unwrap_or_else(|| rule.render_band.clone()),
            sort_anchor_x: override_value
                .and_then(|value| value.sort_anchor_x)
                .unwrap_or(rule.sort_anchor_x),
            sort_anchor_y: override_value
                .and_then(|value| value.sort_anchor_y)
                .unwrap_or(rule.sort_anchor_y),
            default_sort_bias: override_value
                .and_then(|value| value.default_sort_bias)
                .unwrap_or(rule.default_sort_bias),
            geometry: serde_json::Value::Null,
            collision_profile: override_value
                .and_then(|value| value.collision_profile.clone())
                .or_else(|| rule.collision_profile.clone()),
            tags: override_value
                .and_then(|value| value.tags.clone())
                .unwrap_or_else(|| rule.tags.clone()),
            thumbnail: Some(format!(
                "environment_generated/{}",
                object_thumbnail_path(object).display()
            )),
            views,
        });
    }
    objects.append(&mut manual.objects);
    for object in &mut objects {
        if object.category_path.is_empty() {
            object.category_path = vec![object.category.clone()];
        }
        if object.view_mode.is_empty() {
            object.view_mode = view_mode_for_count(object.views.len() as u8)?.into();
        }
        if object.geometry.is_null() {
            object.geometry = geometry_for_profile(object.collision_profile.as_deref());
        }
    }

    const RENDER_BANDS: [&str; 6] = [
        "terrain",
        "terrainDetail",
        "groundCover",
        "depthSorted",
        "overhead",
        "effects",
    ];
    for object in &objects {
        if !RENDER_BANDS.contains(&object.render_band.as_str()) {
            return Err(format!(
                "object {} has unknown render band {}",
                object.id, object.render_band
            )
            .into());
        }
        validate_catalog_view_mode(object)?;
    }

    let mut ids = BTreeSet::new();
    for id in materials
        .iter()
        .map(|material| &material.id)
        .chain(objects.iter().map(|object| &object.id))
    {
        if !ids.insert(id) {
            return Err(format!("duplicate final catalog id {id}").into());
        }
    }

    Ok(Catalog {
        schema_version: 3,
        source_packs: rules
            .packs
            .iter()
            .map(|pack| CatalogSourcePack {
                id: pack.id.clone(),
                name: pack.display_name.clone(),
            })
            .collect(),
        materials,
        objects,
    })
}

fn geometry_for_profile(profile: Option<&str>) -> serde_json::Value {
    use serde_json::json;
    match profile {
        Some("treeTrunk") => json!({
            "footprint": ellipse(0.0, 0.0, 0.52, 0.36),
            "blocking": [ellipse(0.0, -0.03, 0.24, 0.18)],
            "reviewed": false
        }),
        Some("smallRock") => json!({
            "footprint": ellipse(0.0, 0.0, 0.44, 0.30),
            "blocking": [ellipse(0.0, 0.0, 0.34, 0.23)],
            "reviewed": false
        }),
        Some("fence") => json!({
            "footprint": capsule(-0.8, 0.0, 0.8, 0.0, 0.14),
            "blocking": [capsule(-0.8, 0.0, 0.8, 0.0, 0.11)],
            "reviewed": false
        }),
        Some("fenceSegment") => json!({
            "footprint": capsule(-1.6, 0.0, 1.6, 0.0, 0.14),
            "blocking": [capsule(-1.55, 0.0, 1.55, 0.0, 0.11)],
            "reviewed": false
        }),
        Some("building") => json!({
            "footprint": rectangle(0.0, -0.3, 2.4, 1.6),
            "blocking": [rectangle(0.0, -0.3, 2.2, 1.4)],
            "reviewed": false
        }),
        Some("bridge") => json!({
            "footprint": rectangle(0.0, 0.0, 2.2, 1.0),
            "blocking": [
                capsule(-1.0, -0.45, 1.0, -0.45, 0.08),
                capsule(-1.0, 0.45, 1.0, 0.45, 0.08)
            ],
            "walkable": [rectangle(0.0, 0.0, 2.1, 0.75)],
            "reviewed": false
        }),
        _ => serde_json::Value::Null,
    }
}

fn point(x: f64, y: f64) -> serde_json::Value {
    serde_json::json!({"x": x, "y": y})
}

fn ellipse(x: f64, y: f64, radius_x: f64, radius_y: f64) -> serde_json::Value {
    serde_json::json!({
        "type": "ellipse",
        "center": point(x, y),
        "radius": point(radius_x, radius_y)
    })
}

fn rectangle(x: f64, y: f64, width: f64, height: f64) -> serde_json::Value {
    serde_json::json!({
        "type": "rectangle",
        "center": point(x, y),
        "size": point(width, height),
        "rotationDegrees": 0.0
    })
}

fn capsule(start_x: f64, start_y: f64, end_x: f64, end_y: f64, radius: f64) -> serde_json::Value {
    serde_json::json!({
        "type": "capsule",
        "start": point(start_x, start_y),
        "end": point(end_x, end_y),
        "radius": radius
    })
}

fn validated_view_count(
    kind: &str,
    number: u32,
    allowed: &[u8],
    views: &BTreeMap<u8, SourceImage>,
) -> Result<u8> {
    let actual = views.keys().copied().collect::<Vec<_>>();
    let Some(count) = allowed
        .iter()
        .copied()
        .find(|count| actual == (1..=*count).collect::<Vec<_>>())
    else {
        return Err(format!(
            "{kind} {number} has views {actual:?}; allowed complete counts are {allowed:?}"
        )
        .into());
    };
    if ![4, 8].contains(&count) {
        return Err(format!("{kind} {number} has unsupported directional count {count}").into());
    }
    Ok(count)
}

fn view_mode_for_count(count: u8) -> Result<&'static str> {
    match count {
        1 => Ok("fixed"),
        4 => Ok("fourWay"),
        8 => Ok("eightWay"),
        _ => Err(format!("unsupported view count {count}; expected 1, 4, or 8").into()),
    }
}

fn validate_catalog_view_mode(object: &CatalogObject) -> Result<()> {
    let expected = match object.view_mode.as_str() {
        "fixed" => vec!["south"],
        "fourWay" => vec!["south", "west", "east", "north"],
        "eightWay" => DIRECTIONS.to_vec(),
        mode => return Err(format!("object {} has unknown view mode {mode}", object.id).into()),
    };
    let actual = object
        .views
        .keys()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let wanted = expected.into_iter().collect::<BTreeSet<_>>();
    if actual != wanted {
        return Err(format!(
            "object {} declares {} but has directions {:?}",
            object.id, object.view_mode, actual
        )
        .into());
    }
    Ok(())
}

fn inspect_image(root: &Path, path: &Path) -> Result<SourceImage> {
    let (width, height) = image::image_dimensions(path)?;
    Ok(SourceImage {
        source: relative_path(root, path)?,
        width,
        height,
        sha256: sha256_file(path)?,
    })
}

fn material_stem(material: &DiscoveredMaterial) -> String {
    if material.kind == "ground" {
        format!("{:03}", material.number)
    } else {
        format!("{}_{:03}", material.kind, material.number)
    }
}

fn material_image_path(material: &DiscoveredMaterial, role: &str) -> PathBuf {
    PathBuf::from("materials")
        .join(&material.pack_id)
        .join(format!("{}_{role}.png", material_stem(material)))
}

fn material_thumbnail_path(material: &DiscoveredMaterial) -> PathBuf {
    PathBuf::from("thumbnails")
        .join(&material.pack_id)
        .join("ground")
        .join(format!("{}.png", material_stem(material)))
}

fn object_image_path(object: &DiscoveredObject, view: u8) -> PathBuf {
    PathBuf::from("objects")
        .join(&object.pack_id)
        .join(&object.kind)
        .join(match object.source_variant {
            Some(variant) => format!("{:03}_v{variant}_{view}.png", object.number),
            None => format!("{:03}_{view}.png", object.number),
        })
}

fn object_thumbnail_path(object: &DiscoveredObject) -> PathBuf {
    PathBuf::from("thumbnails")
        .join(&object.pack_id)
        .join(&object.kind)
        .join(match object.source_variant {
            Some(variant) => format!("{:03}_v{variant}.png", object.number),
            None => format!("{:03}.png", object.number),
        })
}

fn generated_object_id(object: &DiscoveredObject) -> String {
    let base = format!("{}.{}.{:03}", object.pack_id, object.kind, object.number);
    match object.source_variant {
        Some(variant) => format!("{base}.v{variant}"),
        None => base,
    }
}

fn copy_if_changed(root: &Path, source: &SourceImage, destination: &Path) -> Result<()> {
    if destination.is_file() && sha256_file(destination)? == source.sha256 {
        return Ok(());
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(root.join(&source.source), destination)?;
    Ok(())
}

fn make_thumbnail(source: &Path, destination: &Path, fill: bool) -> Result<()> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    let image = image::open(source)?;
    let resized = if fill {
        image.resize_to_fill(192, 192, FilterType::Lanczos3)
    } else {
        image.thumbnail(184, 184)
    };
    let mut canvas = RgbaImage::new(192, 192);
    let x = (192_u32.saturating_sub(resized.width())) / 2;
    let y = (192_u32.saturating_sub(resized.height())) / 2;
    canvas.copy_from(&resized.to_rgba8(), x, y)?;
    DynamicImage::ImageRgba8(canvas).save_with_format(destination, ImageFormat::Png)?;
    Ok(())
}

fn soft_decal_pixels(source: &Path) -> Result<RgbaImage> {
    let mut image = image::open(source)?.to_rgba8();
    let half_width = image.width() as f64 / 2.0;
    let half_height = image.height() as f64 / 2.0;
    for y in 0..image.height() {
        for x in 0..image.width() {
            let normalized_x = (x as f64 + 0.5 - half_width) / half_width;
            let normalized_y = (y as f64 + 0.5 - half_height) / half_height;
            let distance = (normalized_x * normalized_x + normalized_y * normalized_y).sqrt();
            let fade = soft_decal_alpha(distance);
            let pixel = image.get_pixel_mut(x, y);
            pixel.0[3] = (pixel.0[3] as f64 * fade).round() as u8;
        }
    }
    Ok(image)
}

fn soft_decal_alpha(distance: f64) -> f64 {
    if distance <= 0.68 {
        1.0
    } else if distance >= 1.0 {
        0.0
    } else {
        let t = (distance - 0.68) / 0.32;
        1.0 - t * t * (3.0 - 2.0 * t)
    }
}

fn make_soft_decal(source: &Path, destination: &Path) -> Result<()> {
    let expected = soft_decal_pixels(source)?;
    if destination.is_file() && image::open(destination)?.to_rgba8() == expected {
        return Ok(());
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    DynamicImage::ImageRgba8(expected).save_with_format(destination, ImageFormat::Png)?;
    Ok(())
}

fn verify_soft_decal(source: &Path, destination: &Path) -> Result<()> {
    require_file(destination)?;
    if image::open(destination)?.to_rgba8() != soft_decal_pixels(source)? {
        return Err(format!("generated soft decal is stale: {}", destination.display()).into());
    }
    Ok(())
}

fn verify_copy(source: &SourceImage, destination: &Path) -> Result<()> {
    require_file(destination)?;
    let actual = sha256_file(destination)?;
    if actual != source.sha256 {
        return Err(format!("generated asset is stale: {}", destination.display()).into());
    }
    Ok(())
}

fn require_file(path: &Path) -> Result<()> {
    if !path.is_file() {
        return Err(format!("missing generated file: {}", path.display()).into());
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut reader = BufReader::new(fs::File::open(path)?);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn parse_capture(captures: &regex::Captures<'_>, index: usize) -> Result<u32> {
    Ok(captures
        .get(index)
        .ok_or("missing regex capture")?
        .as_str()
        .parse()?)
}

fn relative_path(root: &Path, path: &Path) -> Result<String> {
    Ok(path
        .strip_prefix(root)?
        .to_string_lossy()
        .replace('\\', "/"))
}

fn title_case(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut bytes = serde_json::to_vec_pretty(value)?;
    bytes.push(b'\n');
    fs::write(path, bytes)?;
    Ok(())
}

fn print_summary(manifest: &Manifest, action: &str) {
    let mut counts = BTreeMap::<&str, usize>::new();
    for object in &manifest.objects {
        *counts.entry(&object.kind).or_default() += 1;
    }
    println!(
        "{action} {} materials and {} object families",
        manifest.materials.len(),
        manifest.objects.len()
    );
    for (kind, count) in counts {
        println!("  {kind}: {count}");
    }
    let mut statuses = BTreeMap::<&str, usize>::new();
    for source in &manifest.sources {
        *statuses.entry(&source.status).or_default() += 1;
    }
    println!("  source coverage:");
    for (status, count) in statuses {
        println!("    {status}: {count}");
    }
    for warning in &manifest.warnings {
        println!("warning: {warning}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direction_order_matches_other_worlds_documentation() {
        assert_eq!(DIRECTIONS[0], "south");
        assert_eq!(DIRECTIONS[3], "north");
        assert_eq!(DIRECTIONS[7], "northEast");
    }

    #[test]
    fn validates_complete_view_sets() {
        let image = SourceImage {
            source: "Tree1_1.png".into(),
            width: 1,
            height: 1,
            sha256: "hash".into(),
        };
        let complete = (1..=4).map(|view| (view, image.clone())).collect();
        assert_eq!(
            validated_view_count("bush", 1, &[4, 8], &complete).unwrap(),
            4
        );

        let incomplete = [(1, image)].into_iter().collect();
        assert!(validated_view_count("bush", 1, &[4, 8], &incomplete).is_err());
    }

    #[test]
    fn only_supported_visual_view_modes_are_emitted() {
        assert_eq!(view_mode_for_count(1).unwrap(), "fixed");
        assert_eq!(view_mode_for_count(4).unwrap(), "fourWay");
        assert_eq!(view_mode_for_count(8).unwrap(), "eightWay");
        assert!(view_mode_for_count(2).is_err());
    }

    #[test]
    fn split_fixed_variants_have_stable_distinct_ids() {
        let object = DiscoveredObject {
            pack_id: "ow3".into(),
            kind: "wall".into(),
            category_path: vec!["Buildings".into(), "Building Parts".into()],
            number: 5,
            source_variant: Some(3),
            view_mode: "fixed".into(),
            views: BTreeMap::new(),
        };

        assert_eq!(generated_object_id(&object), "ow3.wall.005.v3");
        assert_eq!(
            object_image_path(&object, 1),
            PathBuf::from("objects/ow3/wall/005_v3_1.png")
        );
        assert_eq!(
            object_thumbnail_path(&object),
            PathBuf::from("thumbnails/ow3/wall/005_v3.png")
        );
    }

    #[test]
    fn collision_profiles_keep_canopy_separate_from_tree_trunk() {
        let geometry = geometry_for_profile(Some("treeTrunk"));
        assert_eq!(geometry["footprint"]["type"], "ellipse");
        assert_eq!(geometry["blocking"][0]["type"], "ellipse");
        assert!(
            geometry["blocking"][0]["radius"]["x"].as_f64().unwrap()
                < geometry["footprint"]["radius"]["x"].as_f64().unwrap()
        );
        assert_eq!(geometry["reviewed"], false);
    }

    #[test]
    fn generated_fence_collision_reaches_neighboring_path_pieces() {
        let geometry = geometry_for_profile(Some("fenceSegment"));
        assert_eq!(geometry["footprint"]["type"], "capsule");
        assert_eq!(geometry["footprint"]["start"]["x"], -1.6);
        assert_eq!(geometry["footprint"]["end"]["x"], 1.6);
        assert_eq!(geometry["blocking"][0]["end"]["x"], 1.55);
    }

    #[test]
    fn generated_material_decal_has_an_opaque_center_and_soft_edge() {
        assert_eq!(soft_decal_alpha(0.0), 1.0);
        assert_eq!(soft_decal_alpha(0.68), 1.0);
        assert!(soft_decal_alpha(0.8) < 1.0);
        assert!(soft_decal_alpha(0.8) > 0.0);
        assert_eq!(soft_decal_alpha(1.0), 0.0);
    }

    #[test]
    fn release_images_are_downscaled_without_losing_source_dimensions() {
        let root =
            std::env::temp_dir().join(format!("neura-release-image-test-{}", std::process::id()));
        let image_root = root.join("images");
        fs::create_dir_all(&image_root).unwrap();
        let source = image_root.join("large.png");
        DynamicImage::ImageRgba8(RgbaImage::new(200, 100))
            .save_with_format(&source, ImageFormat::Png)
            .unwrap();

        let mut images = BTreeMap::new();
        let release_path = register_release_image(
            &root,
            Path::new("images"),
            "large.png",
            Some(64),
            &mut images,
        )
        .unwrap();
        let output = &images["large.png"];

        assert_eq!(release_path, output.release_path);
        assert_eq!((output.source_width, output.source_height), (200, 100));
        assert_eq!((output.output_width, output.output_height), (64, 32));
        let decoded = image::load_from_memory(&output.bytes).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (64, 32));
        fs::remove_dir_all(root).unwrap();
    }
}
