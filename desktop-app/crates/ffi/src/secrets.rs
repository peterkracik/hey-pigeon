//! `SecretStore` for native shells.
//! Apple targets: the Keychain via `keyring` (`apple-native` covers iOS and
//! macOS; items land in the app's own keychain access group, so a device
//! backup restores them). Everywhere else (Linux CI, tests): a 0600 JSON
//! file next to the database — the same dev fallback the Tauri shell uses.

use heypigeon_core::ports::{SecretStore, StoreError};

fn err(e: impl std::fmt::Display) -> StoreError {
    StoreError(e.to_string())
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
mod keychain {
    use super::*;

    pub struct KeyringSecretStore {
        service: String,
    }

    impl KeyringSecretStore {
        pub fn new(service: &str) -> Self {
            Self {
                service: service.to_string(),
            }
        }

        fn entry(&self, key: &str) -> Result<keyring::Entry, StoreError> {
            keyring::Entry::new(&self.service, key).map_err(err)
        }
    }

    impl SecretStore for KeyringSecretStore {
        fn get(&self, key: &str) -> Result<Option<String>, StoreError> {
            match self.entry(key)?.get_password() {
                Ok(v) => Ok(Some(v)),
                Err(keyring::Error::NoEntry) => Ok(None),
                Err(e) => Err(err(e)),
            }
        }

        fn set(&self, key: &str, value: &str) -> Result<(), StoreError> {
            self.entry(key)?.set_password(value).map_err(err)
        }

        fn delete(&self, key: &str) -> Result<(), StoreError> {
            match self.entry(key)?.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(e) => Err(err(e)),
            }
        }
    }
}

#[cfg(not(any(target_os = "ios", target_os = "macos")))]
mod file {
    use super::*;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::Mutex;

    pub struct FileSecretStore {
        path: PathBuf,
        cache: Mutex<HashMap<String, String>>,
    }

    impl FileSecretStore {
        pub fn open(path: PathBuf) -> Result<Self, StoreError> {
            let cache = match std::fs::read_to_string(&path) {
                Ok(s) => serde_json::from_str(&s).map_err(err)?,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
                Err(e) => return Err(err(e)),
            };
            Ok(Self {
                path,
                cache: Mutex::new(cache),
            })
        }

        fn persist(&self, cache: &HashMap<String, String>) -> Result<(), StoreError> {
            let json = serde_json::to_string_pretty(cache).map_err(err)?;
            std::fs::write(&self.path, json).map_err(err)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o600))
                    .map_err(err)?;
            }
            Ok(())
        }
    }

    impl SecretStore for FileSecretStore {
        fn get(&self, key: &str) -> Result<Option<String>, StoreError> {
            Ok(self.cache.lock().map_err(err)?.get(key).cloned())
        }

        fn set(&self, key: &str, value: &str) -> Result<(), StoreError> {
            let mut cache = self.cache.lock().map_err(err)?;
            cache.insert(key.to_string(), value.to_string());
            self.persist(&cache)
        }

        fn delete(&self, key: &str) -> Result<(), StoreError> {
            let mut cache = self.cache.lock().map_err(err)?;
            cache.remove(key);
            self.persist(&cache)
        }
    }
}

/// The store for this target. `service` is the keychain service name
/// (`app.heypigeon`, shared with the desktop build so a Mac shell built on
/// this crate would see the same items); `data_dir` hosts the file fallback.
pub fn default_secret_store(
    service: &str,
    data_dir: &std::path::Path,
) -> Result<Box<dyn SecretStore + Send + Sync>, StoreError> {
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        let _ = data_dir;
        Ok(Box::new(keychain::KeyringSecretStore::new(service)))
    }
    #[cfg(not(any(target_os = "ios", target_os = "macos")))]
    {
        let _ = service;
        Ok(Box::new(file::FileSecretStore::open(
            data_dir.join("secrets.dev.json"),
        )?))
    }
}
