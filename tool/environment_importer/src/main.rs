use clap::{Parser, Subcommand};
use image::{DynamicImage, GenericImage, ImageFormat, RgbaImage, imageops::FilterType};
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fs;
use std::io::{BufReader, Read};
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
    /// Split the authored environment document into runtime world chunks.
    BuildWorld,
    /// Verify the generated world manifest and chunks.
    CheckWorld,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rules {
    schema_version: u32,
    pack_id: String,
    source_root: PathBuf,
    generated_image_root: PathBuf,
    catalog_path: PathBuf,
    manifest_path: PathBuf,
    overrides_path: PathBuf,
    manual_catalog_path: PathBuf,
    geometry_overrides_catalog_path: PathBuf,
    source_world_path: PathBuf,
    world_manifest_path: PathBuf,
    world_chunks_root: PathBuf,
    world_chunk_size: f64,
    world_width: f64,
    world_height: f64,
    player_spawn: RulePoint,
    ground: GroundRule,
    objects: Vec<ObjectRule>,
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
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObjectRule {
    kind: String,
    category: String,
    pattern: String,
    directionless_pattern: Option<String>,
    expected_views: u8,
    render_scale: f64,
    render_band: String,
    sort_anchor_x: f64,
    sort_anchor_y: f64,
    default_sort_bias: f64,
    pivot_x: f64,
    pivot_y: f64,
    collision_profile: String,
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
    number: u32,
    tile: SourceImage,
    decal: SourceImage,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct DiscoveredObject {
    kind: String,
    category: String,
    number: u32,
    expected_views: u8,
    directionless: bool,
    views: BTreeMap<u8, SourceImage>,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    schema_version: u32,
    pack_id: String,
    materials: Vec<DiscoveredMaterial>,
    objects: Vec<DiscoveredObject>,
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
    view_images: Option<BTreeMap<String, String>>,
    #[serde(default)]
    exclude: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Catalog {
    schema_version: u32,
    materials: Vec<CatalogMaterial>,
    objects: Vec<CatalogObject>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogMaterial {
    id: String,
    name: String,
    texture: String,
    decal: String,
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
    #[serde(default = "default_pivot_x")]
    pivot_x: f64,
    #[serde(default = "default_pivot_y")]
    pivot_y: f64,
}

fn default_pivot_x() -> f64 {
    0.5
}

fn default_render_band() -> String {
    "depthSorted".to_owned()
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
    }
    Ok(())
}

fn scan(root: &Path, rules: &Rules) -> Result<Manifest> {
    let source_root = root.join(&rules.source_root);
    let tile_regex = Regex::new(&rules.ground.tile_pattern)?;
    let decal_regex = Regex::new(&rules.ground.decal_pattern)?;
    let object_regexes = rules
        .objects
        .iter()
        .map(|rule| {
            Ok((
                Regex::new(&rule.pattern)?,
                rule.directionless_pattern
                    .as_ref()
                    .map(|pattern| Regex::new(pattern))
                    .transpose()?,
            ))
        })
        .collect::<Result<Vec<_>>>()?;

    let mut tiles = BTreeMap::<u32, SourceImage>::new();
    let mut decals = BTreeMap::<u32, SourceImage>::new();
    let mut grouped = BTreeMap::<(usize, u32), BTreeMap<u8, SourceImage>>::new();
    let mut directionless = BTreeMap::<(usize, u32), SourceImage>::new();

    for entry in fs::read_dir(&source_root)? {
        let path = entry?.path();
        if !path.is_file() {
            continue;
        }
        let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };

        if let Some(captures) = tile_regex.captures(file_name) {
            tiles.insert(parse_capture(&captures, 1)?, inspect_image(root, &path)?);
            continue;
        }
        if let Some(captures) = decal_regex.captures(file_name) {
            decals.insert(parse_capture(&captures, 1)?, inspect_image(root, &path)?);
            continue;
        }

        for (rule_index, (view_regex, directionless_regex)) in object_regexes.iter().enumerate() {
            if let Some(captures) = view_regex.captures(file_name) {
                let number = parse_capture(&captures, 1)?;
                let view = parse_capture(&captures, 2)? as u8;
                let replaced = grouped
                    .entry((rule_index, number))
                    .or_default()
                    .insert(view, inspect_image(root, &path)?);
                if replaced.is_some() {
                    return Err(format!("duplicate view for {file_name}").into());
                }
                break;
            }
            if let Some(captures) = directionless_regex
                .as_ref()
                .and_then(|regex| regex.captures(file_name))
            {
                let number = parse_capture(&captures, 1)?;
                directionless.insert((rule_index, number), inspect_image(root, &path)?);
                break;
            }
        }
    }

    let material_numbers = tiles
        .keys()
        .chain(decals.keys())
        .copied()
        .collect::<BTreeSet<_>>();
    let mut materials = Vec::new();
    for number in material_numbers {
        let tile = tiles
            .remove(&number)
            .ok_or_else(|| format!("ground {number} has a decal but no tile"))?;
        let decal = decals
            .remove(&number)
            .ok_or_else(|| format!("ground {number} has a tile but no decal"))?;
        materials.push(DiscoveredMaterial {
            number,
            tile,
            decal,
        });
    }

    let mut warnings = Vec::new();
    let mut objects = Vec::new();
    for ((rule_index, number), mut views) in grouped {
        let rule = &rules.objects[rule_index];
        validate_views(&rule.kind, number, rule.expected_views, &views)?;
        objects.push(DiscoveredObject {
            kind: rule.kind.clone(),
            category: rule.category.clone(),
            number,
            expected_views: rule.expected_views,
            directionless: false,
            views: std::mem::take(&mut views),
        });
    }
    for ((rule_index, number), image) in directionless {
        let rule = &rules.objects[rule_index];
        if objects
            .iter()
            .any(|object| object.kind == rule.kind && object.number == number)
        {
            return Err(format!(
                "{} {number} has directional and directionless files",
                rule.kind
            )
            .into());
        }
        warnings.push(format!(
            "{}.{} is directionless; all views use {}",
            rule.kind, number, image.source
        ));
        objects.push(DiscoveredObject {
            kind: rule.kind.clone(),
            category: rule.category.clone(),
            number,
            expected_views: rule.expected_views,
            directionless: true,
            views: (1..=rule.expected_views)
                .map(|view| (view, image.clone()))
                .collect(),
        });
    }
    objects.sort_by(|left, right| {
        left.kind
            .cmp(&right.kind)
            .then(left.number.cmp(&right.number))
    });

    Ok(Manifest {
        schema_version: 1,
        pack_id: rules.pack_id.clone(),
        materials,
        objects,
        warnings,
    })
}

fn build(root: &Path, rules: &Rules, manifest: &Manifest) -> Result<()> {
    let overrides: Overrides = read_json(&root.join(&rules.overrides_path))?;
    let manual: Catalog = read_json(&root.join(&rules.manual_catalog_path))?;
    let catalog = create_catalog(rules, manifest, &overrides, manual)?;
    let generated_root = root.join(&rules.generated_image_root);

    for material in &manifest.materials {
        let directory = generated_root.join("materials");
        copy_if_changed(
            root,
            &material.tile,
            &directory.join(format!("{:03}_tile.png", material.number)),
        )?;
        copy_if_changed(
            root,
            &material.decal,
            &directory.join(format!("{:03}_decal.png", material.number)),
        )?;
        make_thumbnail(
            &root.join(&material.tile.source),
            &generated_root
                .join("thumbnails/ground")
                .join(format!("{:03}.png", material.number)),
            true,
        )?;
    }
    for object in &manifest.objects {
        for (view, image) in &object.views {
            copy_if_changed(
                root,
                image,
                &generated_root
                    .join("objects")
                    .join(&object.kind)
                    .join(format!("{:03}_{view}.png", object.number)),
            )?;
        }
        let preview = object.views.get(&1).expect("validated first view");
        make_thumbnail(
            &root.join(&preview.source),
            &generated_root
                .join("thumbnails")
                .join(&object.kind)
                .join(format!("{:03}.png", object.number)),
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
    for material in &manifest.materials {
        verify_copy(
            &material.tile,
            &generated_root.join(format!("materials/{:03}_tile.png", material.number)),
        )?;
        verify_copy(
            &material.decal,
            &generated_root.join(format!("materials/{:03}_decal.png", material.number)),
        )?;
        require_file(
            &generated_root.join(format!("thumbnails/ground/{:03}.png", material.number)),
        )?;
    }
    for object in &manifest.objects {
        for (view, image) in &object.views {
            verify_copy(
                image,
                &generated_root.join(format!(
                    "objects/{}/{:03}_{view}.png",
                    object.kind, object.number
                )),
            )?;
        }
        require_file(&generated_root.join(format!(
            "thumbnails/{}/{:03}.png",
            object.kind, object.number
        )))?;
    }
    Ok(())
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

fn check_world(root: &Path, rules: &Rules) -> Result<()> {
    let (expected_manifest, expected_chunks) = generate_world(root, rules)?;
    let expected_manifest: serde_json::Value =
        serde_json::from_slice(&serde_json::to_vec(&expected_manifest)?)?;
    let actual_manifest: serde_json::Value = read_json(&root.join(&rules.world_manifest_path))?;
    if actual_manifest != expected_manifest {
        return Err("environment world manifest is stale; run build-world".into());
    }
    let chunks_root = root.join(&rules.world_chunks_root);
    for (name, expected) in &expected_chunks {
        let expected: serde_json::Value = serde_json::from_slice(&serde_json::to_vec(expected)?)?;
        let actual: serde_json::Value = read_json(&chunks_root.join(name))?;
        if actual != expected {
            return Err(format!("environment chunk {name} is stale; run build-world").into());
        }
    }
    let actual_names = fs::read_dir(&chunks_root)?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| name.ends_with(".json"))
        .collect::<BTreeSet<_>>();
    let expected_names = expected_chunks.keys().cloned().collect::<BTreeSet<_>>();
    if actual_names != expected_names {
        return Err("world chunk directory contains missing or stale chunk files".into());
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
        let min_x = xs.iter().copied().fold(f64::INFINITY, f64::min) - radius;
        let max_x = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max) + radius;
        let min_y = ys.iter().copied().fold(f64::INFINITY, f64::min) - radius;
        let max_y = ys.iter().copied().fold(f64::NEG_INFINITY, f64::max) + radius;
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
        let generated_id = format!("{}.ground.{:03}", rules.pack_id, material.number);
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
                .unwrap_or_else(|| format!("Ground {:03}", material.number)),
            texture: override_value
                .and_then(|value| value.texture.clone())
                .unwrap_or_else(|| {
                    format!(
                        "environment_generated/materials/{:03}_tile.png",
                        material.number
                    )
                }),
            decal: override_value
                .and_then(|value| value.decal.clone())
                .unwrap_or_else(|| {
                    format!(
                        "environment_generated/materials/{:03}_decal.png",
                        material.number
                    )
                }),
            default_radius: override_value
                .and_then(|value| value.default_radius)
                .unwrap_or(1.8),
            tags: override_value
                .and_then(|value| value.tags.clone())
                .unwrap_or_default(),
            thumbnail: Some(format!(
                "environment_generated/thumbnails/ground/{:03}.png",
                material.number
            )),
        });
    }
    materials.append(&mut manual.materials);

    let mut objects = Vec::new();
    for object in &manifest.objects {
        let rule = rules
            .objects
            .iter()
            .find(|rule| rule.kind == object.kind)
            .ok_or_else(|| format!("missing rule for {}", object.kind))?;
        let generated_id = format!("{}.{}.{:03}", rules.pack_id, object.kind, object.number);
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
                                    "environment_generated/objects/{}/{:03}_{view}.png",
                                    object.kind, object.number
                                )
                            }),
                        pivot_x,
                        pivot_y,
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
                .unwrap_or_else(|| format!("{} {:03}", title_case(&object.kind), object.number)),
            category: object.category.clone(),
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
            collision_profile: Some(
                override_value
                    .and_then(|value| value.collision_profile.clone())
                    .unwrap_or_else(|| rule.collision_profile.clone()),
            ),
            tags: override_value
                .and_then(|value| value.tags.clone())
                .unwrap_or_default(),
            thumbnail: Some(format!(
                "environment_generated/thumbnails/{}/{:03}.png",
                object.kind, object.number
            )),
            views,
        });
    }
    objects.append(&mut manual.objects);
    for object in &mut objects {
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
        schema_version: 2,
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

fn validate_views(
    kind: &str,
    number: u32,
    expected: u8,
    views: &BTreeMap<u8, SourceImage>,
) -> Result<()> {
    let actual = views.keys().copied().collect::<Vec<_>>();
    let wanted = (1..=expected).collect::<Vec<_>>();
    if actual != wanted {
        return Err(format!("{kind} {number} has views {actual:?}; expected {wanted:?}").into());
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
        assert!(validate_views("bush", 1, 4, &complete).is_ok());

        let incomplete = [(1, image)].into_iter().collect();
        assert!(validate_views("bush", 1, 4, &incomplete).is_err());
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
}
