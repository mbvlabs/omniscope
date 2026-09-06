use nucleo_matcher::{
    Config, Matcher, Utf32String,
    pattern::{AtomKind, CaseMatching, Normalization, Pattern},
};
use rayon::prelude::*;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::cmp::Ordering;
use std::path::Path;
use std::sync::{
    Mutex,
    atomic::{AtomicU64, Ordering as AtomicOrdering},
};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Default, Deserialize)]
pub struct Item {
    #[serde(default)]
    pub id: String,
    pub kind: String,
    pub label: String,
    #[serde(default)]
    pub path: String,
    #[serde(flatten)]
    extra: Map<String, Value>,
}

pub struct Candidate {
    item: Item,
    text: Utf32String,
    label_lower: String,
}

impl Candidate {
    pub fn from_item(item: Item) -> Self {
        let mut text = format!("{} {}", item.label, item.path);
        for field in ["detail", "description", "category", "aliases"] {
            match item.extra.get(field) {
                Some(Value::String(value)) => {
                    text.push(' ');
                    text.push_str(value);
                }
                Some(Value::Array(values)) => {
                    for value in values.iter().filter_map(Value::as_str) {
                        text.push(' ');
                        text.push_str(value);
                    }
                }
                _ => {}
            }
        }
        Self {
            label_lower: item.label.to_lowercase(),
            item,
            text: text.as_str().into(),
        }
    }

    fn file(path: &Path, root: &Path) -> Option<Self> {
        // Never return a lossy pathname that could open a different file.
        let path_string = path.to_str()?.to_owned();
        let label = path.file_name()?.to_str()?.to_owned();
        let relative = path.strip_prefix(root).ok()?.to_str()?;
        Some(Self {
            text: relative.into(),
            label_lower: label.to_lowercase(),
            item: Item {
                kind: "file".into(),
                path: path_string,
                label,
                ..Item::default()
            },
        })
    }

    fn row(&self, pattern: &Pattern, matcher: &mut Matcher) -> Value {
        let mut row = self.item.extra.clone();
        let id = if self.item.kind == "file" {
            format!("file.{}", self.item.path)
        } else {
            self.item.id.clone()
        };
        row.insert("id".into(), id.into());
        row.insert("kind".into(), self.item.kind.clone().into());
        row.insert("label".into(), self.item.label.clone().into());
        row.insert("path".into(), self.item.path.clone().into());
        row.insert(
            "labelRanges".into(),
            highlights(&self.item.label, pattern, matcher),
        );
        row.insert(
            "pathRanges".into(),
            highlights(&self.item.path, pattern, matcher),
        );
        Value::Object(row)
    }
}

pub fn index_files(root: &Path) -> Result<Vec<Candidate>, String> {
    if !root.is_dir() {
        return Err("Search root is not a directory".into());
    }
    let files = Mutex::new(Vec::new());
    let mut walker = ignore::WalkBuilder::new(root);
    walker
        .hidden(false)
        .follow_links(false)
        .threads(4)
        .filter_entry(|entry| {
            !(entry.file_type().is_some_and(|kind| kind.is_dir())
                && matches!(
                    entry.file_name().to_str(),
                    Some(".git" | "node_modules" | ".cache")
                ))
        });
    walker.build_parallel().run(|| {
        Box::new(|entry| {
            if let Ok(entry) = entry
                && entry.file_type().is_some_and(|kind| kind.is_file())
                && let Some(candidate) = Candidate::file(entry.path(), root)
            {
                files.lock().unwrap().push(candidate);
            }
            ignore::WalkState::Continue
        })
    });
    let mut files = files.into_inner().unwrap();
    files.sort_unstable_by(|a, b| a.item.path.cmp(&b.item.path));
    Ok(files)
}

#[derive(Default)]
pub struct Catalog {
    pub items: Vec<Candidate>,
    pub files: Vec<Candidate>,
    pub version: u64,
}

impl Catalog {
    pub fn same_files(&self, files: &[Candidate]) -> bool {
        self.files.len() == files.len()
            && self
                .files
                .iter()
                .zip(files)
                .all(|(a, b)| a.item.path == b.item.path)
    }

    fn get(&self, index: usize) -> &Candidate {
        if index < self.items.len() {
            &self.items[index]
        } else {
            &self.files[index - self.items.len()]
        }
    }
}

#[derive(Clone, Deserialize)]
pub struct Query {
    pub id: u64,
    pub query: String,
    pub mode: String,
    #[serde(default)]
    pub offset: usize,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    100
}

struct Hit {
    index: usize,
    tier: u8,
    score: u32,
}

#[derive(Default)]
pub struct SearchCache {
    key: Option<(String, String, u64)>,
    matches: Vec<Hit>,
    sorted: usize,
}

impl SearchCache {
    pub fn page(
        &mut self,
        catalog: &Catalog,
        query: &Query,
        generation: &AtomicU64,
        revision: u64,
    ) -> Option<(Vec<Value>, usize)> {
        let pattern = Pattern::new(
            query.query.trim(),
            CaseMatching::Ignore,
            Normalization::Smart,
            AtomKind::Fuzzy,
        );
        let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
        let key = (query.query.clone(), query.mode.clone(), catalog.version);
        if self.key.as_ref() != Some(&key) {
            self.key = None;
            self.matches.clear();
            self.sorted = 0;
            let lower = query.query.trim().to_lowercase();
            // Keep matching off the IPC reader and use a bounded worker pool.
            // Every worker owns its matcher scratch space; superseded queries
            // stop scoring immediately. Only the requested page is sorted.
            let candidates = if query.mode == "apps" || query.mode == "launchers" {
                catalog.items.len()
            } else {
                catalog.items.len() + catalog.files.len()
            };
            self.matches = (0..candidates)
                .into_par_iter()
                .with_min_len(4096)
                .map_init(
                    || Matcher::new(Config::DEFAULT.match_paths()),
                    |matcher, index| {
                        if generation.load(AtomicOrdering::Relaxed) != revision {
                            return None;
                        }
                        let candidate = catalog.get(index);
                        let item = &candidate.item;
                        if !in_scope(&query.mode, &item.kind) {
                            return None;
                        }
                        let score = pattern.score(candidate.text.slice(..), matcher)?;
                        let tier = if lower.is_empty() {
                            match item.kind.as_str() {
                                "app" => 3,
                                "launcher" => 2,
                                _ => 1,
                            }
                        } else if candidate.label_lower == lower {
                            4
                        } else if candidate.label_lower.starts_with(&lower) {
                            3
                        } else if candidate.label_lower.contains(&lower) {
                            2
                        } else {
                            1
                        };
                        Some(Hit {
                            index,
                            tier,
                            score: score + if item.kind == "app" { 5 } else { 0 },
                        })
                    },
                )
                .flatten()
                .collect();
            if generation.load(AtomicOrdering::Relaxed) != revision {
                return None;
            }
            self.key = Some(key);
        }
        let compare = |a: &Hit, b: &Hit| -> Ordering {
            b.tier
                .cmp(&a.tier)
                .then_with(|| b.score.cmp(&a.score))
                .then_with(|| {
                    catalog
                        .get(a.index)
                        .label_lower
                        .cmp(&catalog.get(b.index).label_lower)
                })
                .then_with(|| {
                    catalog
                        .get(a.index)
                        .item
                        .path
                        .cmp(&catalog.get(b.index).item.path)
                })
                .then_with(|| a.index.cmp(&b.index))
        };
        let total = self.matches.len();
        let start = query.offset.min(total);
        let end = start.saturating_add(query.limit.min(200)).min(total);
        if end > self.sorted {
            let remaining = &mut self.matches[self.sorted..];
            let count = end - self.sorted;
            if count < remaining.len() {
                remaining.select_nth_unstable_by(count, compare);
            }
            remaining[..count].sort_unstable_by(compare);
            self.sorted = end;
        }
        if generation.load(AtomicOrdering::Relaxed) != revision {
            return None;
        }
        let rows = self.matches[start..end]
            .iter()
            .map(|hit| catalog.get(hit.index).row(&pattern, &mut matcher))
            .collect();
        Some((rows, total))
    }
}

fn in_scope(mode: &str, kind: &str) -> bool {
    match mode {
        "all" => true,
        "apps" => kind == "app",
        "launchers" => kind == "launcher",
        "files" => kind == "file",
        _ => false,
    }
}

fn highlights(text: &str, pattern: &Pattern, matcher: &mut Matcher) -> Value {
    let haystack: Utf32String = text.into();
    let mut positions = Vec::new();
    // Highlight individual matching words even when other words matched a path
    // or alias. Nucleo positions are graphemes; QML uses UTF-16 code units.
    for atom in &pattern.atoms {
        atom.indices(haystack.slice(..), matcher, &mut positions);
    }
    positions.sort_unstable();
    positions.dedup();
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    let mut offset = 0;
    for (index, (byte_index, grapheme)) in text.grapheme_indices(true).enumerate() {
        let end = offset + grapheme.encode_utf16().count();
        let match_index = if text.is_ascii() { byte_index } else { index };
        if positions.binary_search(&(match_index as u32)).is_ok() {
            if let Some(last) = ranges.last_mut()
                && last.1 == offset
            {
                last.1 = end;
            } else {
                ranges.push((offset, end));
            }
        }
        offset = end;
    }
    Value::Array(
        ranges
            .into_iter()
            .map(|(start, end)| json!({"start": start, "end": end}))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(kind: &str, label: &str, path: &str) -> Candidate {
        Candidate::from_item(Item {
            id: label.into(),
            kind: kind.into(),
            label: label.into(),
            path: path.into(),
            ..Item::default()
        })
    }
    fn query(text: &str) -> Query {
        Query {
            id: 1,
            query: text.into(),
            mode: "all".into(),
            offset: 0,
            limit: 100,
        }
    }

    #[test]
    fn ranking_scopes_and_noncontiguous_matches() {
        let catalog = Catalog {
            items: vec![
                item("file", "ScopeModel.js", "/src/ScopeModel.js"),
                item("app", "Scope", "/apps/scope.desktop"),
                item("launcher", "Scope settings", "/menu"),
            ],
            ..Catalog::default()
        };
        let mut cache = SearchCache::default();
        let gen_id = AtomicU64::new(1);
        let (rows, _) = cache.page(&catalog, &query("scope"), &gen_id, 1).unwrap();
        assert_eq!(rows[0]["label"], "Scope");
        let mut q = query("scpmdl");
        q.mode = "files".into();
        let (rows, total) = cache.page(&catalog, &q, &gen_id, 1).unwrap();
        assert_eq!(total, 1);
        assert_eq!(rows[0]["label"], "ScopeModel.js");
        assert!(!rows[0]["labelRanges"].as_array().unwrap().is_empty());
    }

    #[test]
    fn pagination_is_complete_stable_and_cancellable() {
        let catalog = Catalog {
            items: (0..351)
                .rev()
                .map(|n| item("file", &format!("file{n:03}"), "/file"))
                .collect(),
            ..Catalog::default()
        };
        let gen_id = AtomicU64::new(1);
        let mut cache = SearchCache::default();
        let mut names = Vec::new();
        for offset in [0, 100, 200, 300] {
            let mut q = query("file");
            q.offset = offset;
            let (rows, total) = cache.page(&catalog, &q, &gen_id, 1).unwrap();
            assert_eq!(total, 351);
            names.extend(
                rows.into_iter()
                    .map(|r| r["label"].as_str().unwrap().to_owned()),
            );
        }
        assert_eq!(
            names,
            (0..351).map(|n| format!("file{n:03}")).collect::<Vec<_>>()
        );
        assert!(cache.page(&catalog, &query("other"), &gen_id, 0).is_none());
    }

    #[test]
    fn unicode_ranges_use_utf16_and_escape_free_data() {
        let pattern = Pattern::new(
            "cafe",
            CaseMatching::Ignore,
            Normalization::Smart,
            AtomKind::Fuzzy,
        );
        let mut matcher = Matcher::new(Config::DEFAULT);
        assert_eq!(
            highlights("🦀 café.txt", &pattern, &mut matcher),
            json!([{"start": 3, "end": 7}])
        );
        assert_eq!(
            highlights("🦀 cafe\u{301}.txt", &pattern, &mut matcher),
            json!([{"start": 3, "end": 8}])
        );
        assert_eq!(
            highlights("\r\ncafe.txt", &pattern, &mut matcher),
            json!([{"start": 2, "end": 6}])
        );
    }

    #[test]
    fn words_can_match_paths_and_aliases_and_actions_survive() {
        let mut app = Item {
            id: "app.editor".into(),
            kind: "app".into(),
            label: "Editor".into(),
            path: "/apps/editor.desktop".into(),
            ..Item::default()
        };
        app.extra.insert("aliases".into(), json!(["coding"]));
        app.extra
            .insert("action".into(), json!("unchanged command"));
        let catalog = Catalog {
            items: vec![Candidate::from_item(app)],
            ..Catalog::default()
        };
        let (rows, _) = SearchCache::default()
            .page(&catalog, &query("coding editor"), &AtomicU64::new(1), 1)
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["action"], "unchanged command");
    }
}
