//! `SecretStore` for native shells.
//! macOS: the Keychain via `keyring`. iOS: the Keychain directly, so that
//! items can be read while the device is locked (see `keychain` below).
//! Either way items land in the app's own keychain access group, and a
//! device backup restores them. Everywhere else (Linux CI, tests): a 0600
//! JSON file next to the database — the same dev fallback the Tauri shell
//! uses.

use heypigeon_core::ports::{SecretStore, StoreError};

fn err(e: impl std::fmt::Display) -> StoreError {
    StoreError(e.to_string())
}

#[cfg(target_os = "macos")]
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

/// The iPhone's and iPad's Keychain, spoken to directly.
///
/// `keyring` adds an item without saying when it may be read, and iOS then
/// keeps it readable only while the device is unlocked. A push or a
/// background refresh that woke the app on a locked phone could not read
/// the refresh token: the sync failed with "User interaction is not
/// allowed" (`errSecInteractionNotAllowed`) and no notification came.
/// Items are stored readable after the first unlock since the restart
/// instead, which is what background work needs, and still travel with an
/// encrypted device backup as before. The items keep the shape `keyring`
/// gave them (generic password, service, account), so an install's existing
/// ones are found and only their protection is changed.
#[cfg(target_os = "ios")]
mod keychain {
    use super::*;
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use security_framework::access_control::{ProtectionMode, SecAccessControl};
    use security_framework::passwords::{
        delete_generic_password, get_generic_password, set_generic_password_options,
        PasswordOptions,
    };
    use security_framework_sys::access_control::{
        kSecAttrAccessibleAfterFirstUnlock, kSecAttrAccessibleWhenUnlocked,
    };
    use security_framework_sys::item::{kSecAttrService, kSecClass, kSecClassGenericPassword};
    use security_framework_sys::keychain_item::SecItemUpdate;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[link(name = "Security", kind = "framework")]
    extern "C" {
        /// The attribute the protection classes are values of;
        /// `security-framework-sys` declares only the values.
        static kSecAttrAccessible: CFStringRef;
    }

    const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

    pub struct KeychainSecretStore {
        service: String,
        /// Whether the items an older build stored have been moved to the
        /// new protection. Tried until it works: the Keychain only
        /// re-protects an item while the device is unlocked.
        migrated: AtomicBool,
    }

    impl KeychainSecretStore {
        pub fn new(service: &str) -> Self {
            let store = Self {
                service: service.to_string(),
                migrated: AtomicBool::new(false),
            };
            store.migrate();
            store
        }

        /// Move every item of this service that is readable only while
        /// unlocked to "after first unlock". The query matches on the old
        /// protection, so once nothing is left this is one lookup that
        /// finds nothing.
        fn migrate(&self) {
            if self.migrated.load(Ordering::Relaxed) {
                return;
            }
            let service = CFString::new(&self.service);
            // SAFETY: the statics are constants of Security.framework,
            // valid for the life of the process; `wrap_under_get_rule`
            // retains them, and the dictionaries outlive the call.
            let status = unsafe {
                let key = |k: CFStringRef| CFString::wrap_under_get_rule(k);
                let value = |v: CFStringRef| CFString::wrap_under_get_rule(v).as_CFType();
                let query: CFDictionary<CFString, CFType> = CFDictionary::from_CFType_pairs(&[
                    (key(kSecClass), value(kSecClassGenericPassword)),
                    (key(kSecAttrService), service.as_CFType()),
                    (
                        key(kSecAttrAccessible),
                        value(kSecAttrAccessibleWhenUnlocked),
                    ),
                ]);
                let update: CFDictionary<CFString, CFType> = CFDictionary::from_CFType_pairs(&[(
                    key(kSecAttrAccessible),
                    value(kSecAttrAccessibleAfterFirstUnlock),
                )]);
                SecItemUpdate(query.as_concrete_TypeRef(), update.as_concrete_TypeRef())
            };
            match status {
                0 => {
                    log::info!("keychain: stored items are now readable after first unlock");
                    self.migrated.store(true, Ordering::Relaxed);
                }
                ERR_SEC_ITEM_NOT_FOUND => self.migrated.store(true, Ordering::Relaxed),
                // Locked, most likely: the next read or write tries again.
                code => log::debug!("keychain: items not re-protected yet (OSStatus {code})"),
            }
        }
    }

    impl SecretStore for KeychainSecretStore {
        fn get(&self, key: &str) -> Result<Option<String>, StoreError> {
            self.migrate();
            match get_generic_password(&self.service, key) {
                Ok(bytes) => String::from_utf8(bytes).map(Some).map_err(err),
                Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(None),
                Err(e) => Err(err(e)),
            }
        }

        fn set(&self, key: &str, value: &str) -> Result<(), StoreError> {
            self.migrate();
            // A new item gets the protection; for one that exists only the
            // value is replaced, and `migrate` sees to its protection.
            let mut options = PasswordOptions::new_generic_password(&self.service, key);
            options.set_access_control(
                SecAccessControl::create_with_protection(
                    Some(ProtectionMode::AccessibleAfterFirstUnlock),
                    0,
                )
                .map_err(err)?,
            );
            set_generic_password_options(value.as_bytes(), options).map_err(err)
        }

        fn delete(&self, key: &str) -> Result<(), StoreError> {
            match delete_generic_password(&self.service, key) {
                Ok(()) => Ok(()),
                Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(()),
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
    #[cfg(target_os = "ios")]
    {
        let _ = data_dir;
        Ok(Box::new(keychain::KeychainSecretStore::new(service)))
    }
    #[cfg(target_os = "macos")]
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
