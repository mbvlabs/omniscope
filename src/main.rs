mod search;

use search::{Candidate, Catalog, Query, SearchCache};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, mpsc};
use std::time::Instant;

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Request {
    Search(Query),
    Replace { items: Vec<search::Item> },
    Refresh,
    Cancel,
}

enum Event {
    Request(Request, u64),
    Indexed(Result<Vec<Candidate>, String>, f64),
    Error(String),
    Stop,
}

fn emit(value: &Value) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn refresh(root: PathBuf, sender: mpsc::SyncSender<Event>, scanning: Arc<AtomicBool>) {
    if scanning.swap(true, Ordering::Relaxed) {
        return;
    }
    std::thread::spawn(move || {
        let started = Instant::now();
        let result = search::index_files(&root);
        let _ = sender.send(Event::Indexed(
            result,
            started.elapsed().as_secs_f64() * 1000.0,
        ));
    });
}

fn main() -> io::Result<()> {
    rayon::ThreadPoolBuilder::new()
        .num_threads(std::thread::available_parallelism().map_or(2, |n| n.get().min(8)))
        .build_global()
        .map_err(io::Error::other)?;
    // An explicit root is useful for integration tests and benchmarking.
    let root = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .ok_or_else(|| io::Error::other("HOME is not set"))?;
    let root = root.canonicalize()?;
    let generation = Arc::new(AtomicU64::new(0));
    let scanning = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = mpsc::sync_channel(64);
    let reader_sender = sender.clone();
    let reader_generation = generation.clone();
    std::thread::spawn(move || {
        // Bound individual requests without allowing read_line to allocate an
        // arbitrarily large buffer. Oversized messages are discarded to newline.
        let mut input = io::stdin().lock();
        loop {
            let mut line = Vec::new();
            let mut oversized = false;
            loop {
                let Ok(buffer) = input.fill_buf() else {
                    let _ = reader_sender.send(Event::Stop);
                    return;
                };
                if buffer.is_empty() {
                    let _ = reader_sender.send(Event::Stop);
                    return;
                }
                let newline = buffer.iter().position(|b| *b == b'\n');
                let length = newline.map_or(buffer.len(), |i| i + 1);
                if line.len() + length <= 4 * 1024 * 1024 && !oversized {
                    line.extend_from_slice(&buffer[..length]);
                } else {
                    oversized = true;
                }
                input.consume(length);
                if newline.is_some() {
                    break;
                }
            }
            let event = if oversized {
                Event::Error("Search request exceeds 4 MiB".into())
            } else {
                match serde_json::from_slice::<Request>(&line) {
                    Ok(request) => {
                        let revision = if matches!(
                            request,
                            Request::Search(_) | Request::Replace { .. } | Request::Cancel
                        ) {
                            reader_generation.fetch_add(1, Ordering::Relaxed) + 1
                        } else {
                            reader_generation.load(Ordering::Relaxed)
                        };
                        Event::Request(request, revision)
                    }
                    Err(error) => Event::Error(format!("Invalid search request: {error}")),
                }
            };
            if reader_sender.send(event).is_err() {
                return;
            }
        }
    });

    emit(&json!({"type": "ready", "protocol": 1}))?;
    refresh(root.clone(), sender.clone(), scanning.clone());
    let mut catalog = Catalog::default();
    let mut cache = SearchCache::default();
    let mut active: Option<(Query, u64)> = None;
    let mut indexed = false;
    while let Ok(first) = receiver.recv() {
        let mut events = vec![first];
        events.extend(receiver.try_iter());
        let mut changed = false;
        for event in events {
            match event {
                Event::Stop => return Ok(()),
                Event::Error(message) => emit(&json!({"type": "error", "message": message}))?,
                Event::Indexed(result, elapsed) => {
                    // A refresh immediately after `indexed` must not be lost.
                    scanning.store(false, Ordering::Relaxed);
                    match result {
                        Ok(files) => {
                            let updated = !indexed || !catalog.same_files(&files);
                            if updated {
                                catalog.files = files;
                                catalog.version += 1;
                            }
                            indexed = true;
                            emit(
                                &json!({"type": "indexed", "count": catalog.files.len(), "elapsedMs": elapsed}),
                            )?;
                            if updated {
                                if let Some((query, _)) = &mut active {
                                    query.offset = 0;
                                }
                                changed = true;
                            }
                        }
                        Err(message) => emit(&json!({"type": "error", "message": message}))?,
                    }
                }
                Event::Request(request, revision) => match request {
                    Request::Refresh => refresh(root.clone(), sender.clone(), scanning.clone()),
                    Request::Cancel => active = None,
                    Request::Replace { items } => {
                        catalog.items = items
                            .into_iter()
                            .filter(|item| item.kind == "app" || item.kind == "launcher")
                            .map(Candidate::from_item)
                            .collect();
                        catalog.version += 1;
                        if let Some((query, current)) = &mut active {
                            query.offset = 0;
                            *current = revision;
                        }
                        changed = true;
                    }
                    Request::Search(mut query) => {
                        query.limit = query.limit.clamp(1, 200);
                        if query.query.len() > 2048 {
                            emit(&json!({"type": "error", "message": "Search query is too long"}))?;
                            active = None;
                        } else {
                            active = Some((query, revision));
                            changed = true;
                        }
                    }
                },
            }
        }
        if changed && let Some((query, revision)) = &active {
            let started = Instant::now();
            if let Some((rows, total)) = cache.page(&catalog, query, &generation, *revision) {
                if generation.load(Ordering::Relaxed) != *revision {
                    continue;
                }
                emit(
                    &json!({"type": "results", "id": query.id, "query": query.query,
                    "mode": query.mode, "offset": query.offset, "rows": rows, "total": total,
                    "indexVersion": catalog.version, "indexed": indexed,
                    "elapsedMs": started.elapsed().as_secs_f64() * 1000.0}),
                )?;
            }
        }
    }
    Ok(())
}
