use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Clone)]
pub struct SupabaseClient {
    client: Client,
    url: String,
    anon_key: String,
    service_role_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupabaseAuthResponse {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    pub user: SupabaseUser,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupabaseUser {
    pub id: String,
    pub email: Option<String>,
    pub user_metadata: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct SupabaseSignUpResponse {
    pub id: String,
    pub email: Option<String>,
    pub confirmation_sent_at: Option<String>,
    pub user_metadata: Option<serde_json::Value>,
}

#[derive(Debug)]
pub enum SupabaseSignUpResult {
    Session(SupabaseAuthResponse),
    PendingVerification(SupabaseSignUpResponse),
}

impl SupabaseClient {
    pub fn new(url: String, anon_key: String, service_role_key: Option<String>) -> Self {
        // Avoid macOS system proxy resolution in sandboxed / CI environments.
        // `reqwest::Client::new()` may consult SystemConfiguration and can panic in restricted contexts.
        let client = Client::builder()
            .no_proxy()
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            client,
            url,
            anon_key,
            service_role_key,
        }
    }

    pub async fn sign_in_with_password(
        &self,
        email: &str,
        password: &str,
    ) -> Result<SupabaseAuthResponse, String> {
        let endpoint = format!("{}/auth/v1/token?grant_type=password", self.url);

        let response = self
            .client
            .post(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", &self.anon_key))
            .header("Content-Type", "application/json")
            .json(&serde_json::json!({
                "email": email,
                "password": password
            }))
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            response
                .json::<SupabaseAuthResponse>()
                .await
                .map_err(|e| e.to_string())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Auth Error: {}", error_text))
        }
    }

    pub async fn sign_in_with_phone(
        &self,
        phone: &str,
        token: &str,
    ) -> Result<SupabaseAuthResponse, String> {
        let endpoint = format!("{}/auth/v1/token", self.url);

        let response = self
            .client
            .post(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", &self.anon_key))
            .header("Content-Type", "application/json")
            .json(&serde_json::json!({
                "phone": phone,
                "token": token,
                "type": "sms",
                "grant_type": "otp"
            }))
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            response
                .json::<SupabaseAuthResponse>()
                .await
                .map_err(|e| e.to_string())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Phone Auth Error: {}", error_text))
        }
    }

    pub async fn refresh_session(
        &self,
        refresh_token: &str,
    ) -> Result<SupabaseAuthResponse, String> {
        let endpoint = format!("{}/auth/v1/token?grant_type=refresh_token", self.url);

        let response = self
            .client
            .post(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", &self.anon_key))
            .header("Content-Type", "application/json")
            .json(&serde_json::json!({
                "refresh_token": refresh_token
            }))
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            response
                .json::<SupabaseAuthResponse>()
                .await
                .map_err(|e| e.to_string())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Refresh Error: {}", error_text))
        }
    }

    pub async fn send_phone_otp(&self, phone: &str) -> Result<(), String> {
        let endpoint = format!("{}/auth/v1/otp", self.url);

        let response = self
            .client
            .post(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", &self.anon_key))
            .header("Content-Type", "application/json")
            .json(&serde_json::json!({
                "phone": phone
            }))
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            Ok(())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Send OTP Error: {}", error_text))
        }
    }

    pub async fn sign_up(
        &self,
        email: &str,
        password: &str,
        metadata: Option<serde_json::Value>,
    ) -> Result<SupabaseSignUpResult, String> {
        let endpoint = format!("{}/auth/v1/signup", self.url);

        let mut body = serde_json::json!({
            "email": email,
            "password": password
        });
        if let Some(metadata) = metadata {
            body["data"] = metadata;
        }

        let response = self
            .client
            .post(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", &self.anon_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if response.status().is_success() {
            let bytes = response.bytes().await.map_err(|e| e.to_string())?;
            let value: serde_json::Value =
                serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;

            // When email confirmation is enabled, Supabase returns a user object without tokens.
            if value.get("access_token").is_some() {
                let auth = serde_json::from_value::<SupabaseAuthResponse>(value)
                    .map_err(|e| e.to_string())?;
                return Ok(SupabaseSignUpResult::Session(auth));
            }

            let sign_up = serde_json::from_value::<SupabaseSignUpResponse>(value)
                .map_err(|e| e.to_string())?;
            Ok(SupabaseSignUpResult::PendingVerification(sign_up))
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Register Error: {}", error_text))
        }
    }

    pub async fn get_user(&self, access_token: &str) -> Result<SupabaseUser, String> {
        let endpoint = format!("{}/auth/v1/user", self.url);
        let response = self
            .client
            .get(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", access_token))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if response.status().is_success() {
            response
                .json::<SupabaseUser>()
                .await
                .map_err(|e| e.to_string())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Get User Error: {}", error_text))
        }
    }

    pub async fn get_nebula_id(
        &self,
        access_token: &str,
        user_id: &str,
    ) -> Result<Option<String>, String> {
        let endpoint = format!(
            "{}/rest/v1/users?select=nebula_id&id=eq.{}&limit=1",
            self.url, user_id
        );
        let response = self
            .client
            .get(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", access_token))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if response.status().is_success() {
            let v = response
                .json::<serde_json::Value>()
                .await
                .map_err(|e| e.to_string())?;
            if let Some(arr) = v.as_array() {
                if let Some(first) = arr.first() {
                    let nid = first
                        .get("nebula_id")
                        .and_then(|x| x.as_str())
                        .map(|s| s.to_string());
                    return Ok(nid);
                }
            }
            Ok(None)
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Get NebulaID Error: {}", error_text))
        }
    }

    pub async fn update_user_metadata(
        &self,
        access_token: &str,
        metadata: serde_json::Value,
    ) -> Result<(), String> {
        let endpoint = format!("{}/auth/v1/user", self.url);
        let body = serde_json::json!({ "data": metadata });
        let response = self
            .client
            .put(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", access_token))
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if response.status().is_success() {
            Ok(())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Update Metadata Error: {}", error_text))
        }
    }

    pub async fn patch_users_row(
        &self,
        user_id: &str,
        payload: serde_json::Value,
        auth_token: Option<&str>,
    ) -> Result<(), String> {
        let endpoint = format!("{}/rest/v1/users?id=eq.{}", self.url, user_id);
        let mut req = self
            .client
            .patch(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Content-Type", "application/json")
            .header("Prefer", "return=representation")
            .json(&payload);

        let bearer = if let Some(tok) = auth_token {
            tok.to_string()
        } else if let Some(service_key) = self.service_role_key.as_ref() {
            service_key.to_string()
        } else {
            // Fall back to anon role (may be blocked by RLS), but keep behavior compatible with older builds.
            self.anon_key.clone()
        };
        req = req.header("Authorization", format!("Bearer {}", bearer));

        let response = req.send().await.map_err(|e| e.to_string())?;
        if response.status().is_success() {
            Ok(())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Patch Users Error: {}", error_text))
        }
    }

    pub async fn upload_to_storage(
        &self,
        access_token: &str,
        bucket: &str,
        object_path: &str,
        bytes: Vec<u8>,
        content_type: &str,
    ) -> Result<(), String> {
        let endpoint = format!("{}/storage/v1/object/{}/{}", self.url, bucket, object_path);
        let response = self
            .client
            .post(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Authorization", format!("Bearer {}", access_token))
            .header("Content-Type", content_type)
            .header("x-upsert", "true")
            .body(bytes)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if response.status().is_success() {
            Ok(())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Storage Upload Error: {}", error_text))
        }
    }

    pub fn public_object_url(&self, bucket: &str, object_path: &str) -> String {
        format!(
            "{}/storage/v1/object/public/{}/{}",
            self.url, bucket, object_path
        )
    }

    /// Best-effort probe for a public storage object.
    ///
    /// Some deployments may not allow `HEAD`; we fall back to a minimal ranged `GET`.
    pub async fn public_object_exists(&self, bucket: &str, object_path: &str) -> bool {
        let url = self.public_object_url(bucket, object_path);

        let head = self
            .client
            .head(&url)
            .header("apikey", &self.anon_key)
            .send()
            .await;
        if let Ok(resp) = head {
            if resp.status().is_success() {
                return true;
            }
        }

        let get = self
            .client
            .get(&url)
            .header("apikey", &self.anon_key)
            .header("Range", "bytes=0-0")
            .send()
            .await;
        matches!(get, Ok(resp) if resp.status().is_success())
    }

    pub async fn update_user_email(&self, access_token: &str, email: &str) -> Result<(), String> {
        let endpoint = format!("{}/auth/v1/user", self.url);
        let response = self
            .client
            .put(&endpoint)
            .header("apikey", &self.anon_key)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", access_token))
            .json(&serde_json::json!({"email": email}))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if response.status().is_success() {
            Ok(())
        } else {
            let error_text = response.text().await.unwrap_or_default();
            Err(format!("Supabase Update Email Error: {}", error_text))
        }
    }
}
