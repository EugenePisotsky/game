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
    ground: GroundRule,
    objects: Vec<ObjectRule>,
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
    let expected_catalog =
        serde_json::to_value(create_catalog(rules, manifest, &overrides, manual)?)?;
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
        schema_version: 1,
        materials,
        objects,
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
}
