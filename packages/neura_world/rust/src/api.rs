use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};
use std::sync::atomic::{AtomicU32, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NativeNavigationPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Debug)]
pub struct NativeNavigationTerrainStroke {
    pub points: Vec<NativeNavigationPoint>,
    pub radius: f64,
    pub blocked: bool,
}

#[derive(Clone, Debug)]
pub struct NativeNavigationPolygon {
    pub points: Vec<NativeNavigationPoint>,
}

#[derive(Clone, Debug)]
pub struct NativeNavigationWorldInput {
    pub width: f64,
    pub height: f64,
    pub cell_size: f64,
    pub actor_radius: f64,
    pub base_blocked: bool,
    pub terrain_strokes: Vec<NativeNavigationTerrainStroke>,
    pub object_colliders: Vec<NativeNavigationPolygon>,
}

#[derive(Clone, Debug)]
pub struct NativeNavigationSnapshot {
    pub columns: u32,
    pub rows: u32,
    pub blocked_cells: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct NativeNavigationWorldCreated {
    pub handle: u32,
    pub snapshot: NativeNavigationSnapshot,
}

#[derive(Clone, Debug)]
pub struct NativeNavigationPathResult {
    pub points: Vec<NativeNavigationPoint>,
    pub expanded_nodes: u32,
    pub elapsed_micros: u32,
}

#[derive(Debug)]
struct NavigationWorld {
    width: f64,
    height: f64,
    cell_size: f64,
    columns: usize,
    rows: usize,
    blocked: Vec<u8>,
    actor_radius: f64,
    object_colliders: Vec<NativeNavigationPolygon>,
}

static NEXT_HANDLE: AtomicU32 = AtomicU32::new(1);
static WORLDS: OnceLock<Mutex<HashMap<u32, Arc<NavigationWorld>>>> = OnceLock::new();

fn worlds() -> &'static Mutex<HashMap<u32, Arc<NavigationWorld>>> {
    WORLDS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn native_navigation_world_create(
    input: NativeNavigationWorldInput,
) -> Result<NativeNavigationWorldCreated, String> {
    let world = Arc::new(NavigationWorld::build(input)?);
    let snapshot = world.snapshot();
    let handle = NEXT_HANDLE.fetch_add(1, AtomicOrdering::Relaxed);
    worlds()
        .lock()
        .map_err(|_| "navigation registry lock was poisoned".to_owned())?
        .insert(handle, world);
    Ok(NativeNavigationWorldCreated { handle, snapshot })
}

pub fn native_navigation_world_replace(
    handle: u32,
    input: NativeNavigationWorldInput,
) -> Result<NativeNavigationSnapshot, String> {
    let world = Arc::new(NavigationWorld::build(input)?);
    let snapshot = world.snapshot();
    let previous = worlds()
        .lock()
        .map_err(|_| "navigation registry lock was poisoned".to_owned())?
        .insert(handle, world);
    if previous.is_none() {
        return Err(format!("unknown navigation world handle {handle}"));
    }
    Ok(snapshot)
}

pub fn native_navigation_world_find_path(
    handle: u32,
    start: NativeNavigationPoint,
    destination: NativeNavigationPoint,
) -> Result<NativeNavigationPathResult, String> {
    let world = worlds()
        .lock()
        .map_err(|_| "navigation registry lock was poisoned".to_owned())?
        .get(&handle)
        .cloned()
        .ok_or_else(|| format!("unknown navigation world handle {handle}"))?;
    Ok(world.find_path(start, destination))
}

#[flutter_rust_bridge::frb(sync)]
pub fn native_navigation_world_close(handle: u32) -> bool {
    worlds()
        .lock()
        .map(|mut registry| registry.remove(&handle).is_some())
        .unwrap_or(false)
}

impl NavigationWorld {
    fn build(input: NativeNavigationWorldInput) -> Result<Self, String> {
        if !input.width.is_finite() || input.width <= 0.0 {
            return Err("navigation width must be positive".to_owned());
        }
        if !input.height.is_finite() || input.height <= 0.0 {
            return Err("navigation height must be positive".to_owned());
        }
        if !input.cell_size.is_finite() || input.cell_size <= 0.0 {
            return Err("navigation cell size must be positive".to_owned());
        }
        let columns = (input.width / input.cell_size).ceil() as usize;
        let rows = (input.height / input.cell_size).ceil() as usize;
        let mut world = Self {
            width: input.width,
            height: input.height,
            cell_size: input.cell_size,
            columns,
            rows,
            blocked: vec![u8::from(input.base_blocked); columns * rows],
            actor_radius: input.actor_radius,
            object_colliders: Vec::new(),
        };

        // Terrain is authored in painter's order. Later strokes replace the
        // movement material chosen by earlier strokes, just like rendering.
        for stroke in input.terrain_strokes {
            world.rasterize_stroke(&stroke);
        }
        for polygon in &input.object_colliders {
            world.rasterize_polygon(&polygon.points, input.actor_radius);
        }
        world.object_colliders = input.object_colliders;
        Ok(world)
    }

    fn snapshot(&self) -> NativeNavigationSnapshot {
        NativeNavigationSnapshot {
            columns: self.columns as u32,
            rows: self.rows as u32,
            blocked_cells: self.blocked.clone(),
        }
    }

    fn rasterize_stroke(&mut self, stroke: &NativeNavigationTerrainStroke) {
        if stroke.points.is_empty() || stroke.radius < 0.0 {
            return;
        }
        if stroke.points.len() == 1 {
            let point = stroke.points[0];
            self.rasterize_bounds(
                point.x - stroke.radius,
                point.y - stroke.radius,
                point.x + stroke.radius,
                point.y + stroke.radius,
                |sample| distance_squared(sample, point) <= stroke.radius * stroke.radius,
                stroke.blocked,
            );
            return;
        }
        for pair in stroke.points.windows(2) {
            let start = pair[0];
            let end = pair[1];
            self.rasterize_bounds(
                start.x.min(end.x) - stroke.radius,
                start.y.min(end.y) - stroke.radius,
                start.x.max(end.x) + stroke.radius,
                start.y.max(end.y) + stroke.radius,
                |sample| distance_to_segment(sample, start, end) <= stroke.radius,
                stroke.blocked,
            );
        }
    }

    fn rasterize_polygon(&mut self, points: &[NativeNavigationPoint], padding: f64) {
        if points.len() < 3 {
            return;
        }
        let min_x = points
            .iter()
            .map(|point| point.x)
            .fold(f64::INFINITY, f64::min);
        let min_y = points
            .iter()
            .map(|point| point.y)
            .fold(f64::INFINITY, f64::min);
        let max_x = points
            .iter()
            .map(|point| point.x)
            .fold(f64::NEG_INFINITY, f64::max);
        let max_y = points
            .iter()
            .map(|point| point.y)
            .fold(f64::NEG_INFINITY, f64::max);
        self.rasterize_bounds(
            min_x - padding,
            min_y - padding,
            max_x + padding,
            max_y + padding,
            |sample| polygon_contains_or_near(points, sample, padding),
            true,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn rasterize_bounds(
        &mut self,
        min_x: f64,
        min_y: f64,
        max_x: f64,
        max_y: f64,
        contains: impl Fn(NativeNavigationPoint) -> bool,
        value: bool,
    ) {
        let min_column = ((min_x / self.cell_size).floor() as isize)
            .clamp(0, self.columns.saturating_sub(1) as isize) as usize;
        let max_column = ((max_x / self.cell_size).floor() as isize)
            .clamp(0, self.columns.saturating_sub(1) as isize) as usize;
        let min_row = ((min_y / self.cell_size).floor() as isize)
            .clamp(0, self.rows.saturating_sub(1) as isize) as usize;
        let max_row = ((max_y / self.cell_size).floor() as isize)
            .clamp(0, self.rows.saturating_sub(1) as isize) as usize;
        for row in min_row..=max_row {
            for column in min_column..=max_column {
                let sample = self.center(column, row);
                if contains(sample) {
                    self.blocked[row * self.columns + column] = u8::from(value);
                }
            }
        }
    }

    fn find_path(
        &self,
        start: NativeNavigationPoint,
        destination: NativeNavigationPoint,
    ) -> NativeNavigationPathResult {
        let started = Instant::now();
        let start_cell = self.cell_for(start);
        let requested_end = self.cell_for(destination);
        let Some(end_cell) = self.nearest_open(requested_end) else {
            return self.path_result(Vec::new(), 0, started);
        };
        if self.blocked[start_cell] != 0 {
            return self.path_result(Vec::new(), 0, started);
        }

        let cell_count = self.columns * self.rows;
        let mut open = BinaryHeap::new();
        let mut closed = vec![false; cell_count];
        let mut came_from = vec![usize::MAX; cell_count];
        let mut g_score = vec![f64::INFINITY; cell_count];
        g_score[start_cell] = 0.0;
        open.push(OpenNode {
            index: start_cell,
            f_score: self.heuristic(start_cell, end_cell),
        });
        let mut expanded = 0_u32;

        while let Some(OpenNode { index, .. }) = open.pop() {
            if closed[index] {
                continue;
            }
            closed[index] = true;
            expanded = expanded.saturating_add(1);
            if index == end_cell {
                let points = self.reconstruct(&came_from, start_cell, end_cell, start, destination);
                return self.path_result(points, expanded, started);
            }

            let (column, row) = self.coordinates(index);
            for dy in -1_isize..=1 {
                for dx in -1_isize..=1 {
                    if dx == 0 && dy == 0 {
                        continue;
                    }
                    let next_column = column as isize + dx;
                    let next_row = row as isize + dy;
                    if next_column < 0
                        || next_row < 0
                        || next_column >= self.columns as isize
                        || next_row >= self.rows as isize
                    {
                        continue;
                    }
                    let neighbor = next_row as usize * self.columns + next_column as usize;
                    if closed[neighbor] || self.blocked[neighbor] != 0 {
                        continue;
                    }
                    if dx != 0 && dy != 0 {
                        let horizontal = row * self.columns + next_column as usize;
                        let vertical = next_row as usize * self.columns + column;
                        if self.blocked[horizontal] != 0 || self.blocked[vertical] != 0 {
                            continue;
                        }
                    }
                    let step_cost = if dx != 0 && dy != 0 {
                        std::f64::consts::SQRT_2
                    } else {
                        1.0
                    };
                    let tentative = g_score[index] + step_cost;
                    if tentative >= g_score[neighbor] {
                        continue;
                    }
                    came_from[neighbor] = index;
                    g_score[neighbor] = tentative;
                    open.push(OpenNode {
                        index: neighbor,
                        f_score: tentative + self.heuristic(neighbor, end_cell),
                    });
                }
            }
        }
        self.path_result(Vec::new(), expanded, started)
    }

    fn reconstruct(
        &self,
        came_from: &[usize],
        start_cell: usize,
        end_cell: usize,
        start: NativeNavigationPoint,
        requested_destination: NativeNavigationPoint,
    ) -> Vec<NativeNavigationPoint> {
        let mut reverse = vec![end_cell];
        while *reverse.last().unwrap_or(&start_cell) != start_cell {
            let previous = came_from[*reverse.last().unwrap()];
            if previous == usize::MAX {
                return Vec::new();
            }
            reverse.push(previous);
        }
        reverse.reverse();
        let mut points = vec![start];
        points.extend(reverse.into_iter().skip(1).map(|index| {
            let (column, row) = self.coordinates(index);
            self.center(column, row)
        }));
        if !self.blocked_at_point(requested_destination) {
            points.push(requested_destination);
        }
        self.smooth_visible_segments(&points)
    }

    fn smooth_visible_segments(
        &self,
        points: &[NativeNavigationPoint],
    ) -> Vec<NativeNavigationPoint> {
        if points.len() < 2 {
            return Vec::new();
        }
        let mut result = Vec::new();
        let mut anchor = 0;
        while anchor < points.len() - 1 {
            let mut next = points.len() - 1;
            while next > anchor + 1 && !self.segment_walkable(points[anchor], points[next]) {
                next -= 1;
            }
            result.push(points[next]);
            anchor = next;
        }
        result
    }

    fn segment_walkable(&self, start: NativeNavigationPoint, end: NativeNavigationPoint) -> bool {
        let distance = distance_squared(start, end).sqrt();
        let steps = (distance / (self.cell_size / 3.0)).ceil().max(1.0) as usize;
        (0..=steps).all(|step| {
            let t = step as f64 / steps as f64;
            !self.blocked_at_point(NativeNavigationPoint {
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t,
            })
        })
    }

    fn blocked_at_point(&self, point: NativeNavigationPoint) -> bool {
        if point.x < 0.0 || point.y < 0.0 || point.x > self.width || point.y > self.height {
            return true;
        }
        self.blocked[self.cell_for(point)] != 0
            || self
                .object_colliders
                .iter()
                .any(|polygon| polygon_contains_or_near(&polygon.points, point, self.actor_radius))
    }

    fn nearest_open(&self, requested: usize) -> Option<usize> {
        if self.blocked[requested] == 0 {
            return Some(requested);
        }
        let (requested_x, requested_y) = self.coordinates(requested);
        for radius in 1_isize..=8 {
            for y in requested_y as isize - radius..=requested_y as isize + radius {
                for x in requested_x as isize - radius..=requested_x as isize + radius {
                    if (x - requested_x as isize).abs() != radius
                        && (y - requested_y as isize).abs() != radius
                    {
                        continue;
                    }
                    if x < 0 || y < 0 || x >= self.columns as isize || y >= self.rows as isize {
                        continue;
                    }
                    let index = y as usize * self.columns + x as usize;
                    if self.blocked[index] == 0 {
                        return Some(index);
                    }
                }
            }
        }
        None
    }

    fn heuristic(&self, from: usize, to: usize) -> f64 {
        let (from_x, from_y) = self.coordinates(from);
        let (to_x, to_y) = self.coordinates(to);
        let dx = from_x.abs_diff(to_x) as f64;
        let dy = from_y.abs_diff(to_y) as f64;
        dx.max(dy) + (std::f64::consts::SQRT_2 - 1.0) * dx.min(dy)
    }

    fn cell_for(&self, point: NativeNavigationPoint) -> usize {
        let column = ((point.x / self.cell_size).floor() as isize)
            .clamp(0, self.columns.saturating_sub(1) as isize) as usize;
        let row = ((point.y / self.cell_size).floor() as isize)
            .clamp(0, self.rows.saturating_sub(1) as isize) as usize;
        row * self.columns + column
    }

    fn coordinates(&self, index: usize) -> (usize, usize) {
        (index % self.columns, index / self.columns)
    }

    fn center(&self, column: usize, row: usize) -> NativeNavigationPoint {
        NativeNavigationPoint {
            x: self.width.min((column as f64 + 0.5) * self.cell_size),
            y: self.height.min((row as f64 + 0.5) * self.cell_size),
        }
    }

    fn path_result(
        &self,
        points: Vec<NativeNavigationPoint>,
        expanded_nodes: u32,
        started: Instant,
    ) -> NativeNavigationPathResult {
        NativeNavigationPathResult {
            points,
            expanded_nodes,
            elapsed_micros: started.elapsed().as_micros().min(u32::MAX as u128) as u32,
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct OpenNode {
    index: usize,
    f_score: f64,
}

impl PartialEq for OpenNode {
    fn eq(&self, other: &Self) -> bool {
        self.index == other.index && self.f_score.to_bits() == other.f_score.to_bits()
    }
}

impl Eq for OpenNode {}

impl PartialOrd for OpenNode {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for OpenNode {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .f_score
            .total_cmp(&self.f_score)
            .then_with(|| other.index.cmp(&self.index))
    }
}

fn polygon_contains_or_near(
    polygon: &[NativeNavigationPoint],
    point: NativeNavigationPoint,
    padding: f64,
) -> bool {
    let mut inside = false;
    let mut previous = polygon.len() - 1;
    for current in 0..polygon.len() {
        let a = polygon[current];
        let b = polygon[previous];
        if (a.y > point.y) != (b.y > point.y)
            && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
        {
            inside = !inside;
        }
        if padding > 0.0 && distance_to_segment(point, a, b) <= padding {
            return true;
        }
        previous = current;
    }
    inside
}

fn distance_squared(a: NativeNavigationPoint, b: NativeNavigationPoint) -> f64 {
    let dx = a.x - b.x;
    let dy = a.y - b.y;
    dx * dx + dy * dy
}

fn distance_to_segment(
    point: NativeNavigationPoint,
    start: NativeNavigationPoint,
    end: NativeNavigationPoint,
) -> f64 {
    let dx = end.x - start.x;
    let dy = end.y - start.y;
    let length_squared = dx * dx + dy * dy;
    let t = if length_squared <= f64::EPSILON {
        0.0
    } else {
        (((point.x - start.x) * dx + (point.y - start.y) * dy) / length_squared).clamp(0.0, 1.0)
    };
    let nearest = NativeNavigationPoint {
        x: start.x + dx * t,
        y: start.y + dy * t,
    };
    distance_squared(point, nearest).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_world() -> NavigationWorld {
        NavigationWorld::build(NativeNavigationWorldInput {
            width: 10.0,
            height: 10.0,
            cell_size: 0.4,
            actor_radius: 0.18,
            base_blocked: false,
            terrain_strokes: Vec::new(),
            object_colliders: Vec::new(),
        })
        .unwrap()
    }

    #[test]
    fn finds_a_direct_path_through_empty_ground() {
        let world = empty_world();
        let destination = NativeNavigationPoint { x: 8.0, y: 7.0 };
        let result = world.find_path(NativeNavigationPoint { x: 1.0, y: 1.0 }, destination);
        assert_eq!(result.points.last(), Some(&destination));
        assert!(result.expanded_nodes > 0);
    }

    #[test]
    fn rasterized_polygon_forces_a_detour() {
        let world = NavigationWorld::build(NativeNavigationWorldInput {
            width: 10.0,
            height: 10.0,
            cell_size: 0.4,
            actor_radius: 0.18,
            base_blocked: false,
            terrain_strokes: Vec::new(),
            object_colliders: vec![NativeNavigationPolygon {
                points: vec![
                    NativeNavigationPoint { x: 4.0, y: 3.0 },
                    NativeNavigationPoint { x: 6.0, y: 3.0 },
                    NativeNavigationPoint { x: 6.0, y: 7.0 },
                    NativeNavigationPoint { x: 4.0, y: 7.0 },
                ],
            }],
        })
        .unwrap();
        let result = world.find_path(
            NativeNavigationPoint { x: 2.0, y: 5.0 },
            NativeNavigationPoint { x: 8.0, y: 5.0 },
        );
        assert!(!result.points.is_empty());
        assert!(
            result
                .points
                .iter()
                .any(|point| point.y < 3.0 || point.y > 7.0)
        );
    }

    #[test]
    fn precise_polygon_blocks_points_inside_an_open_edge_cell() {
        let world = NavigationWorld::build(NativeNavigationWorldInput {
            width: 10.0,
            height: 10.0,
            cell_size: 0.4,
            actor_radius: 0.18,
            base_blocked: false,
            terrain_strokes: Vec::new(),
            object_colliders: vec![NativeNavigationPolygon {
                points: vec![
                    NativeNavigationPoint { x: 4.01, y: 3.0 },
                    NativeNavigationPoint { x: 6.0, y: 3.0 },
                    NativeNavigationPoint { x: 6.0, y: 7.0 },
                    NativeNavigationPoint { x: 4.01, y: 7.0 },
                ],
            }],
        })
        .unwrap();

        // The cell center at x=3.8 is outside the 0.18 expansion, but this
        // exact point in the same cell still overlaps the actor clearance.
        assert_eq!(
            world.blocked[world.cell_for(NativeNavigationPoint { x: 3.9, y: 5.0 })],
            0
        );
        assert!(world.blocked_at_point(NativeNavigationPoint { x: 3.9, y: 5.0 }));
    }

    #[test]
    fn later_walkable_terrain_stroke_overrides_blocked_paint() {
        let world = NavigationWorld::build(NativeNavigationWorldInput {
            width: 10.0,
            height: 10.0,
            cell_size: 0.4,
            actor_radius: 0.18,
            base_blocked: false,
            terrain_strokes: vec![
                NativeNavigationTerrainStroke {
                    points: vec![NativeNavigationPoint { x: 5.0, y: 5.0 }],
                    radius: 2.0,
                    blocked: true,
                },
                NativeNavigationTerrainStroke {
                    points: vec![NativeNavigationPoint { x: 5.0, y: 5.0 }],
                    radius: 0.5,
                    blocked: false,
                },
            ],
            object_colliders: Vec::new(),
        })
        .unwrap();
        assert!(!world.blocked_at_point(NativeNavigationPoint { x: 5.0, y: 5.0 }));
        assert!(world.blocked_at_point(NativeNavigationPoint { x: 6.0, y: 5.0 }));
    }
}
