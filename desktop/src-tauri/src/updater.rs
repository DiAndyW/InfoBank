use std::future::Future;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};
use serde::Serialize;
use tauri::{Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum UpdateStatus {
    Off,
    Checking,
    UpToDate { checked_at: String },
    Downloading { version: String },
    Ready { version: String },
    Offline,
    Failed,
}

#[derive(Serialize)]
pub struct UpdateInfo {
    pub current_version: String,
    pub status: UpdateStatus,
}

type Install = Box<dyn FnOnce(bool) -> Result<(), String> + Send>;

#[derive(Clone)]
enum Failure {
    Offline,
    Other(String),
}

trait Source {
    fn check(&mut self) -> impl Future<Output = Result<Option<String>, Failure>> + Send;
    fn download(&mut self) -> impl Future<Output = Result<Install, Failure>> + Send;
}

struct PluginSource {
    updater: tauri_plugin_updater::Updater,
    found: Option<tauri_plugin_updater::Update>,
}

impl PluginSource {
    fn new(builder: tauri_plugin_updater::UpdaterBuilder, check_timeout: Duration) -> tauri_plugin_updater::Result<Self> {
        Ok(Self { updater: builder.timeout(check_timeout).build()?, found: None })
    }
}

fn classify(error: tauri_plugin_updater::Error) -> Failure {
    match error {
        tauri_plugin_updater::Error::Reqwest(e) if e.is_connect() || e.is_timeout() => Failure::Offline,
        other => Failure::Other(other.to_string()),
    }
}

impl Source for PluginSource {
    async fn check(&mut self) -> Result<Option<String>, Failure> {
        self.found = self.updater.check().await.map_err(classify)?;
        Ok(self.found.as_ref().map(|update| update.version.clone()))
    }

    async fn download(&mut self) -> Result<Install, Failure> {
        let mut update = self.found.take().expect("download follows a found update");
        update.timeout = Some(Duration::from_secs(10 * 60));
        let bytes = update.download(|_, _| {}, || {}).await.map_err(classify)?;
        Ok(Box::new(move |relaunch| {
            update.restart_after_install(relaunch).install(bytes).map_err(crate::error_message::message)
        }))
    }
}

struct Inner {
    status: UpdateStatus,
    running: bool,
    last_attempt: Option<SystemTime>,
    install: Option<Install>,
}

pub(crate) struct UpdateState {
    inner: Mutex<Inner>,
    wake: tokio::sync::Notify,
    enabled: bool,
}

impl UpdateState {
    pub(crate) fn new(enabled: bool) -> Self {
        Self {
            inner: Mutex::new(Inner {
                status: if enabled { UpdateStatus::Checking } else { UpdateStatus::Off },
                running: false,
                last_attempt: None,
                install: None,
            }),
            wake: tokio::sync::Notify::new(),
            enabled,
        }
    }

    pub(crate) fn status(&self) -> UpdateStatus {
        self.inner.lock().unwrap().status.clone()
    }

    fn begin(&self, now: SystemTime) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if !self.enabled || inner.running || matches!(inner.status, UpdateStatus::Ready { .. }) {
            return false;
        }
        inner.running = true;
        inner.last_attempt = Some(now);
        true
    }

    fn publish(&self, status: UpdateStatus, emit: &mut impl FnMut(UpdateStatus)) {
        self.inner.lock().unwrap().status = status.clone();
        emit(status);
    }

    async fn perform(&self, source: &mut impl Source, emit: &mut impl FnMut(UpdateStatus)) {
        self.publish(UpdateStatus::Checking, emit);
        let result = async {
            match source.check().await? {
                None => Ok(UpdateStatus::UpToDate { checked_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true) }),
                Some(version) => {
                    self.publish(UpdateStatus::Downloading { version: version.clone() }, emit);
                    let install = source.download().await?;
                    self.inner.lock().unwrap().install = Some(install);
                    Ok(UpdateStatus::Ready { version })
                }
            }
        }.await;
        let status = match result {
            Ok(status) => status,
            Err(Failure::Offline) => UpdateStatus::Offline,
            Err(Failure::Other(_message)) => UpdateStatus::Failed,
        };
        self.publish(status, emit);
        self.inner.lock().unwrap().running = false;
    }

    pub(crate) fn request(&self) {
        if self.begin(SystemTime::now()) {
            self.wake.notify_one();
        }
    }

    async fn check_next(&self, source: &mut impl Source, emit: &mut impl FnMut(UpdateStatus), tick: &mut tokio::time::Interval) {
        let wake = futures_util::future::select(Box::pin(self.wake.notified()), Box::pin(tick.tick())).await;
        if matches!(wake, futures_util::future::Either::Right(_)) {
            let last = self.inner.lock().unwrap().last_attempt;
            if !due(last, SystemTime::now()) || !self.begin(SystemTime::now()) {
                return;
            }
        }
        self.perform(source, emit).await;
    }

    pub(crate) fn install(&self, relaunch: bool, emit: &mut impl FnMut(UpdateStatus)) -> Result<(), String> {
        // Take before installing: Windows exits here, and a restart also runs the exit handler.
        let install = self.inner.lock().unwrap().install.take().ok_or("No update is ready")?;
        if let Err(error) = install(relaunch) {
            self.publish(UpdateStatus::Failed, emit);
            return Err(error);
        }
        Ok(())
    }
}

pub(crate) fn due(last_attempt: Option<SystemTime>, now: SystemTime) -> bool {
    last_attempt.is_none_or(|last| now.duration_since(last).map_or(true, |elapsed| elapsed >= Duration::from_secs(6 * 3600)))
}

pub(crate) fn emit<R: tauri::Runtime>(app: &tauri::AppHandle<R>, status: UpdateStatus) {
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.emit("update-status", status);
    }
}

pub(crate) fn install_on_exit(state: &UpdateState) {
    let install = state.inner.lock().unwrap().install.take();
    if let Some(install) = install && let Err(error) = install(false) {
        eprintln!("{error}");
    }
}

pub(crate) async fn run(app: tauri::AppHandle) {
    let state = &app.state::<crate::AppState>().update;
    let mut source = match PluginSource::new(app.updater_builder(), Duration::from_secs(30)) {
        Ok(source) => source,
        Err(_) => {
            state.publish(UpdateStatus::Failed, &mut |status| emit(&app, status));
            return;
        }
    };
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    loop {
        state.check_next(&mut source, &mut |status| emit(&app, status), &mut tick).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex, atomic::{AtomicUsize, Ordering}};
    use std::time::{Duration, SystemTime};
    use keyring_core::api::CredentialStoreApi;
    use tauri::Manager;

    struct Fake {
        found: Result<Option<String>, Failure>,
        download_fails: bool,
        install_fails: bool,
        installed: Arc<Mutex<Vec<bool>>>,
        calls: Arc<AtomicUsize>,
        gate: Option<tokio::sync::oneshot::Receiver<()>>,
    }

    impl Fake {
        fn update() -> Self {
            Self { found: Ok(Some("0.2.0".into())), download_fails: false, install_fails: false,
                installed: Arc::new(Mutex::new(vec![])), calls: Arc::new(AtomicUsize::new(0)), gate: None }
        }
    }

    impl Source for Fake {
        async fn check(&mut self) -> Result<Option<String>, Failure> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if let Some(gate) = self.gate.take() { gate.await.unwrap(); }
            self.found.clone()
        }
        async fn download(&mut self) -> Result<Install, Failure> {
            if self.download_fails { return Err(Failure::Other("bad signature".into())); }
            let installed = self.installed.clone();
            let fails = self.install_fails;
            Ok(Box::new(move |relaunch| {
                installed.lock().unwrap().push(relaunch);
                if fails { Err("install failed".into()) } else { Ok(()) }
            }))
        }
    }

    async fn check(state: &UpdateState, source: &mut Fake, seen: &mut Vec<UpdateStatus>) {
        if state.begin(SystemTime::now()) {
            state.perform(source, &mut |s| seen.push(s)).await;
        }
    }

    #[test]
    fn stalled_manifest_times_out_offline_and_allows_another_check() {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let (release, hold) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut first, _) = listener.accept().unwrap();
            let read_request = |stream: &mut std::net::TcpStream| {
                for line in BufReader::new(stream).lines() {
                    if line.unwrap().is_empty() { break; }
                }
            };
            read_request(&mut first);
            hold.recv().unwrap();
            drop(first);
            let (mut second, _) = listener.accept().unwrap();
            read_request(&mut second);
            second.write_all(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n").unwrap();
        });
        let app = tauri::test::mock_builder()
            .plugin(tauri_plugin_updater::Builder::new().build())
            .build(tauri::generate_context!(test = true)).unwrap();
        tauri::async_runtime::block_on(async {
            let builder = app.updater_builder().endpoints(vec![endpoint.parse().unwrap()]).unwrap().no_proxy();
            let mut source = PluginSource::new(builder, Duration::from_millis(50)).unwrap();
            let state = UpdateState::new(true);
            assert!(state.begin(SystemTime::now()));
            let result = tokio::time::timeout(Duration::from_secs(1), state.perform(&mut source, &mut |_| {})).await;
            release.send(()).unwrap();
            assert!(result.is_ok(), "stalled manifest never completed");
            assert_eq!(state.status(), UpdateStatus::Offline);
            assert!(state.begin(SystemTime::now()), "timeout left check running");
            state.perform(&mut source, &mut |_| {}).await;
            assert!(matches!(state.status(), UpdateStatus::UpToDate { .. }));
        });
        server.join().unwrap();
    }

    #[test]
    fn a_found_update_downloads_then_is_ready() {
        tauri::async_runtime::block_on(async {
            let state = UpdateState::new(true);
            let mut seen = vec![];
            check(&state, &mut Fake::update(), &mut seen).await;
            assert_eq!(seen, vec![UpdateStatus::Checking, UpdateStatus::Downloading { version: "0.2.0".into() }, UpdateStatus::Ready { version: "0.2.0".into() }]);
            assert!(state.inner.lock().unwrap().install.is_some());
        });
    }

    #[test]
    fn no_update_is_up_to_date_with_a_utc_time() {
        tauri::async_runtime::block_on(async {
            let state = UpdateState::new(true);
            let mut source = Fake::update();
            source.found = Ok(None);
            check(&state, &mut source, &mut vec![]).await;
            let UpdateStatus::UpToDate { checked_at } = state.status() else { panic!("not up to date") };
            assert!(checked_at.ends_with('Z'));
            assert_eq!(chrono::DateTime::parse_from_rfc3339(&checked_at).unwrap().offset().local_minus_utc(), 0);
        });
    }

    #[test]
    fn offline_and_other_failures_are_told_apart() {
        tauri::async_runtime::block_on(async {
            for (failure, want) in [(Failure::Offline, UpdateStatus::Offline), (Failure::Other("invalid feed".into()), UpdateStatus::Failed)] {
                let state = UpdateState::new(true);
                let mut source = Fake::update();
                source.found = Err(failure);
                check(&state, &mut source, &mut vec![]).await;
                assert_eq!(state.status(), want);
            }
            let state = UpdateState::new(true);
            let mut source = Fake::update();
            source.download_fails = true;
            check(&state, &mut source, &mut vec![]).await;
            assert_eq!(state.status(), UpdateStatus::Failed);
            assert!(state.inner.lock().unwrap().install.is_none());
        });
    }

    #[test]
    fn a_check_while_one_runs_or_while_ready_starts_nothing() {
        tauri::async_runtime::block_on(async {
            let state = UpdateState::new(true);
            let mut source = Fake::update();
            let calls = source.calls.clone();
            let (send, receive) = tokio::sync::oneshot::channel();
            source.gate = Some(receive);
            assert!(state.begin(SystemTime::now()));
            let mut emit = |_| {};
            let running = state.perform(&mut source, &mut emit);
            let second = async {
                assert!(!state.begin(SystemTime::now()));
                assert_eq!(calls.load(Ordering::SeqCst), 1);
                send.send(()).unwrap();
            };
            futures_util::future::join(running, second).await;
            assert_eq!(state.status(), UpdateStatus::Ready { version: "0.2.0".into() });
            assert!(!state.begin(SystemTime::now()));
            assert_eq!(calls.load(Ordering::SeqCst), 1);
            let off = UpdateState::new(false);
            assert_eq!(off.status(), UpdateStatus::Off);
            assert!(!off.begin(SystemTime::now()));
        });
    }

    #[test]
    fn due_after_six_hours_on_the_wall_clock() {
        let last = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
        assert!(due(None, last));
        assert!(!due(Some(last), last + Duration::from_secs(5 * 3600 + 59 * 60)));
        assert!(due(Some(last), last + Duration::from_secs(6 * 3600)));
        assert!(due(Some(last), last - Duration::from_secs(1)));
    }

    #[test]
    fn the_held_update_installs_once() {
        tauri::async_runtime::block_on(async {
            for relaunch in [true, false] {
                let state = UpdateState::new(true);
                let mut source = Fake::update();
                check(&state, &mut source, &mut vec![]).await;
                if relaunch { state.install(true, &mut |_| {}).unwrap(); } else { install_on_exit(&state); }
                install_on_exit(&state);
                assert_eq!(*source.installed.lock().unwrap(), vec![relaunch]);
            }
        });
    }

    #[test]
    fn a_failed_install_is_failed_not_ready() {
        tauri::async_runtime::block_on(async {
            let state = UpdateState::new(true);
            let mut source = Fake::update();
            source.install_fails = true;
            check(&state, &mut source, &mut vec![]).await;
            let mut seen = vec![];
            assert_eq!(state.install(true, &mut |s| seen.push(s)), Err("install failed".into()));
            assert_eq!(state.status(), UpdateStatus::Failed);
            assert_eq!(seen, vec![UpdateStatus::Failed]);
            install_on_exit(&state);
            assert_eq!(*source.installed.lock().unwrap(), vec![true]);
            assert!(state.inner.lock().unwrap().install.is_none());
        });
    }

    #[test]
    fn a_refused_connection_counts_as_offline() {
        tauri::async_runtime::block_on(async {
            let error = reqwest::get("http://127.0.0.1:1").await.unwrap_err();
            assert!(matches!(classify(tauri_plugin_updater::Error::Reqwest(error)), Failure::Offline));
        });
    }

    #[test]
    fn a_manual_request_checks_once_even_when_a_tick_overlaps() {
        tauri::async_runtime::block_on(async {
            for overlaps in [false, true] {
                let state = UpdateState::new(true);
                let mut source = Fake::update();
                source.found = Ok(None);
                let mut tick = tokio::time::interval(Duration::from_secs(60));
                if !overlaps { tick.tick().await; }
                state.request();
                let mut seen = vec![];
                let mut emit = |status| seen.push(status);
                tokio::time::timeout(Duration::from_millis(100), state.check_next(&mut source, &mut emit, &mut tick))
                    .await.expect("manual request did not wake the consumer");
                if overlaps {
                    tokio::time::timeout(Duration::from_millis(100), state.check_next(&mut source, &mut emit, &mut tick))
                        .await.expect("overlapping tick was not consumed");
                }
                assert!(tokio::time::timeout(Duration::from_millis(20), state.check_next(&mut source, &mut emit, &mut tick)).await.is_err());
                assert_eq!(source.calls.load(Ordering::SeqCst), 1);
                assert_eq!(seen.len(), 2);
                assert!(matches!(state.status(), UpdateStatus::UpToDate { .. }));
            }
        });
    }

    #[test]
    fn only_the_main_window_can_use_updater_commands() {
        use tauri::test::{INVOKE_KEY, get_ipc_response, mock_builder};
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder().invoke_handler(tauri::generate_handler![
            crate::commands::update_status, crate::commands::check_for_updates, crate::commands::restart_to_update
        ]).build(tauri::generate_context!(test = true)).unwrap();
        // Bypass the capability restriction so this tests the command's own authorization.
        app.add_capability(r#"{"identifier":"updater-command-test","windows":["quick-capture"],"permissions":["allow-update-status","allow-check-for-updates","allow-restart-to-update"]}"#).unwrap();
        let mut app_state = crate::AppState::new(conn, secret, dir.path().to_path_buf());
        app_state.update = UpdateState::new(true);
        let mut source = Fake::update();
        source.install_fails = true;
        tauri::async_runtime::block_on(check(&app_state.update, &mut source, &mut vec![]));
        app.manage(app_state);
        let window = tauri::WebviewWindowBuilder::new(&app, "quick-capture", tauri::WebviewUrl::default()).build().unwrap();
        for cmd in ["restart_to_update", "update_status", "check_for_updates"] {
            let result = get_ipc_response(&window, tauri::webview::InvokeRequest {
                cmd: cmd.into(), callback: tauri::ipc::CallbackFn(0), error: tauri::ipc::CallbackFn(1),
                url: window.url().unwrap(), body: serde_json::json!({}).into(), headers: Default::default(), invoke_key: INVOKE_KEY.to_string(),
            });
            assert!(source.installed.lock().unwrap().is_empty());
            assert_eq!(result.unwrap_err(), serde_json::json!("Only the main window can manage updates"));
            assert!(app.state::<crate::AppState>().update.inner.lock().unwrap().install.is_some());
        }
    }

    #[test]
    fn restart_with_nothing_ready_is_an_error() {
        use tauri::test::{INVOKE_KEY, get_ipc_response, mock_builder};
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let app = mock_builder().invoke_handler(tauri::generate_handler![crate::commands::restart_to_update])
            .build(tauri::generate_context!(test = true)).unwrap();
        app.manage(crate::AppState::new(conn, secret, dir.path().to_path_buf()));
        let window = tauri::WebviewWindowBuilder::new(&app, "main", tauri::WebviewUrl::default()).build().unwrap();
        let result = get_ipc_response(&window, tauri::webview::InvokeRequest {
            cmd: "restart_to_update".into(), callback: tauri::ipc::CallbackFn(0), error: tauri::ipc::CallbackFn(1),
            url: window.url().unwrap(), body: serde_json::json!({}).into(), headers: Default::default(), invoke_key: INVOKE_KEY.to_string(),
        });
        assert_eq!(result.unwrap_err(), serde_json::json!("No update is ready"));
    }
}
