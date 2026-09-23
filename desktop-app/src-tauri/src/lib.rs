mod ai;
mod autolabel;
mod mail;
mod secrets;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            // Mobile has no updater — desktop-only, per Tauri's own guidance.
            #[cfg(desktop)]
            app.handle().plugin(tauri_plugin_updater::Builder::new().build())?;
            let data_dir = tauri::Manager::path(app).app_data_dir()?;
            std::fs::create_dir_all(&data_dir)?;
            // Shared with `ai::init` — see the comment on `mail::init` for why
            // this must be one instance, not one per module.
            let secrets: std::sync::Arc<dyn heypigeon_core::ports::SecretStore + Send + Sync> =
                std::sync::Arc::from(secrets::default_secret_store(&data_dir)?);
            mail::init(app, std::sync::Arc::clone(&secrets))?;
            ai::init(app, secrets);
            autolabel::init(app);
            Ok(())
        })
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_process::init())
        // Mail bodies render in an iframe (untrusted HTML), so link clicks and
        // target=_blank popups still navigate through this webview — cancel any
        // navigation that isn't the app's own origin and hand it to the OS
        // browser instead, same `open` pattern as the OAuth flow (mail.rs).
        .plugin(
            tauri::plugin::Builder::<tauri::Wry>::new("external-links")
                .on_navigation(|_webview, url| {
                    // Only external http(s) links are ever meant to be redirected —
                    // the mail iframe's own `about:srcdoc` load, and any tauri://
                    // / dev-server navigation, must pass through untouched.
                    let is_external_link = matches!(url.scheme(), "http" | "https")
                        && url.scheme() != "tauri"
                        && !(cfg!(debug_assertions) && url.host_str() == Some("localhost"));
                    if !is_external_link {
                        return true;
                    }
                    let _ = std::process::Command::new("open").arg(url.as_str()).spawn();
                    false
                })
                .build(),
        )
        // Refocusing the app is the strongest "is there new mail?" signal.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Focused(true) = event {
                mail::on_focus(tauri::Manager::app_handle(window).clone());
            }
        })
        .invoke_handler(tauri::generate_handler![
            mail::weblog,
            mail::list_accounts,
            mail::list_threads,
            mail::list_labels,
            mail::unread_counts,
            mail::list_scheduled,
            mail::search_threads,
            mail::get_thread,
            mail::mutate,
            mail::set_schedule,
            mail::sync_status,
            mail::sync_now,
            mail::start_gmail_oauth,
            mail::lookup_avatar,
            mail::update_account,
            mail::remove_account,
            mail::update_label,
            mail::delete_label,
            ai::ai_status,
            ai::ai_models,
            ai::set_ai_key,
            ai::remove_ai_key,
            ai::set_ai_model,
            ai::ai_edit_text,
            autolabel::autolabel_status,
            autolabel::set_jev_key,
            autolabel::remove_jev_key,
            autolabel::set_autolabel_enabled,
            autolabel::list_triage_labels,
            autolabel::create_triage_label,
            autolabel::rename_triage_label,
            autolabel::delete_triage_label,
            autolabel::reanalyze_all_triage,
            autolabel::set_manual_triage_labels,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
