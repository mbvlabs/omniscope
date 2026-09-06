use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct Worker {
    child: Child,
    messages: mpsc::Receiver<Value>,
}

impl Worker {
    fn new(root: &std::path::Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_omniscope-search"))
            .arg(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, messages) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else {
                    break;
                };
                if sender.send(serde_json::from_str(&line).unwrap()).is_err() {
                    break;
                }
            }
        });
        Self { child, messages }
    }
    fn send(&mut self, request: Value) {
        writeln!(self.child.stdin.as_mut().unwrap(), "{request}").unwrap();
    }
    fn until(&self, predicate: impl Fn(&Value) -> bool) -> Value {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            let message = self
                .messages
                .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
                .unwrap();
            if predicate(&message) {
                return message;
            }
        }
    }
    fn search(&mut self, id: u64, query: &str, mode: &str, offset: usize) -> Value {
        self.send(json!({"type": "search", "id": id, "query": query, "mode": mode, "offset": offset, "limit": 100}));
        self.until(|r| r["type"] == "results" && r["id"] == id)
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct Fixture(std::path::PathBuf);
impl Fixture {
    fn new() -> Self {
        let id = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("omniscope-protocol-{}-{id}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn file(&self, name: &str) {
        let path = self.0.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "fixture").unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn full_index_protocol_refresh_paging_and_latest_query() {
    let fixture = Fixture::new();
    for n in 0..3501 {
        fixture.file(&format!("file{n:04}.txt"));
    }
    fixture.file(".hidden/ScopeModel.js");
    fixture.file("odd/ 🦀 cafe\u{301}\n<&>.txt ");
    fixture.file(".git/should-not-appear");
    fixture.file("node_modules/should-not-appear");
    fixture.file(".cache/should-not-appear");
    fixture.file("ignored/should-not-appear");
    std::fs::write(fixture.0.join(".gitignore"), "ignored/\n").unwrap();
    let mut worker = Worker::new(&fixture.0);
    assert_eq!(worker.until(|r| r["type"] == "ready")["protocol"], 1);
    let indexed = worker.until(|r| r["type"] == "indexed");
    assert_eq!(indexed["count"], 3504);
    let result = worker.search(1, "scpmdl", "files", 0);
    assert_eq!(result["total"], 1);
    assert_eq!(result["rows"][0]["label"], "ScopeModel.js");
    assert_eq!(
        worker.search(2, "should-not-appear", "files", 0)["total"],
        0
    );
    let odd = worker.search(3, "cafe", "files", 0);
    assert_eq!(
        odd["rows"][0]["path"],
        fixture
            .0
            .join("odd/ 🦀 cafe\u{301}\n<&>.txt ")
            .to_str()
            .unwrap()
    );
    let mut ids = std::collections::HashSet::new();
    for page in 0..36 {
        let result = worker.search(10 + page, "file", "files", page as usize * 100);
        assert_eq!(result["total"], 3501);
        for row in result["rows"].as_array().unwrap() {
            assert!(ids.insert(row["id"].as_str().unwrap().to_owned()));
        }
    }
    assert_eq!(ids.len(), 3501);
    assert!(
        worker.search(50, "file", "files", usize::MAX)["rows"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    worker.send(json!({"type": "replace", "items": [{"id": "app.editor", "kind": "app", "label": "Editor", "aliases": ["coding"], "appId": "editor.desktop"}]}));
    let app = worker.search(51, "coding", "apps", 0);
    assert_eq!(app["total"], 1);
    assert_eq!(app["rows"][0]["appId"], "editor.desktop");
    for id in 100..200 {
        worker.send(json!({"type": "search", "id": id, "query": "file", "mode": "files"}));
    }
    assert_eq!(worker.search(200, "scpmdl", "files", 0)["total"], 1);
    worker.send(json!({"type": "cancel"}));
    fixture.file("fresh-file.txt");
    worker.send(json!({"type": "refresh"}));
    worker.until(|r| r["type"] == "indexed");
    assert_eq!(worker.search(201, "fresh", "files", 0)["total"], 1);
    writeln!(worker.child.stdin.as_mut().unwrap(), "not json").unwrap();
    worker.until(|r| r["type"] == "error");
    assert_eq!(worker.search(202, "editor", "apps", 0)["total"], 1);
    // EOF must stop the helper; it is owned by the QML Process, not a daemon.
    drop(worker.child.stdin.take());
    assert!(worker.child.wait().unwrap().success());
}
