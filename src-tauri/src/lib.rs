mod ai;
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
      let data_dir = tauri::Manager::path(app).app_data_dir()?;
      std::fs::create_dir_all(&data_dir)?;
      // Shared with `ai::init` — see the comment on `mail::init` for why
      // this must be one instance, not one per module.
      let secrets: std::sync::Arc<dyn heypigeon_core::ports::SecretStore + Send + Sync> =
        std::sync::Arc::from(secrets::default_secret_store(&data_dir)?);
      mail::init(app, std::sync::Arc::clone(&secrets))?;
      ai::init(app, secrets);
      Ok(())
    })
    .plugin(tauri_plugin_notification::init())
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
    ])
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
