//! SecretStore adapters.
//! Debug builds: plaintext-on-disk file store (0600) — the macOS keychain
//! re-prompts on every unsigned rebuild, which makes dev iteration unbearable.
//! Release builds: OS keychain via `keyring`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use heypigeon_core::ports::{SecretStore, StoreError};

fn err(e: impl std::fmt::Display) -> StoreError {
    StoreError(e.to_string())
}

// ------------------------------------------------------------ file (debug)

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
        Ok(Self { path, cache: Mutex::new(cache) })
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

// -------------------------------------------------------- keyring (release)

pub struct KeyringSecretStore {
    service: String,
}

impl KeyringSecretStore {
    pub fn new(service: &str) -> Self {
        Self { service: service.to_string() }
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

/// The store the app actually uses for this build profile.
pub fn default_secret_store(
    data_dir: &std::path::Path,
) -> Result<Box<dyn SecretStore + Send + Sync>, StoreError> {
    if cfg!(debug_assertions) {
        Ok(Box::new(FileSecretStore::open(data_dir.join("secrets.dev.json"))?))
    } else {
        Ok(Box::new(KeyringSecretStore::new("app.heypigeon")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_store_round_trip_and_reopen() {
        let dir = std::env::temp_dir().join(format!("heypigeon-secrets-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("secrets.json");
        let _ = std::fs::remove_file(&path);

        let s = FileSecretStore::open(path.clone()).unwrap();
        assert_eq!(s.get("token").unwrap(), None);
        s.set("token", "value-1").unwrap();
        s.set("token", "value-2").unwrap();
        assert_eq!(s.get("token").unwrap().as_deref(), Some("value-2"));

        let s2 = FileSecretStore::open(path.clone()).unwrap();
        assert_eq!(s2.get("token").unwrap().as_deref(), Some("value-2"));
        s2.delete("token").unwrap();
        assert_eq!(s2.get("token").unwrap(), None);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let _ = std::fs::remove_file(&path);
    }
}
