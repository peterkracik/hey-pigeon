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
      mail::init(app)?;
      Ok(())
    })
    .invoke_handler(tauri::generate_handler![
      mail::list_accounts,
      mail::list_threads,
      mail::get_thread,
      mail::mutate,
      mail::sync_now,
      mail::start_gmail_oauth,
      mail::lookup_avatar,
      mail::set_account_color,
      mail::remove_account,
    ])
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
