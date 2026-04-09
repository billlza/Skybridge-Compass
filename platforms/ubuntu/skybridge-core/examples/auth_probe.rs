use skybridge_core::AuthenticationService;

#[tokio::main]
async fn main() {
    let email = std::env::var("SKYBRIDGE_TEST_EMAIL").expect("SKYBRIDGE_TEST_EMAIL");
    let password = std::env::var("SKYBRIDGE_TEST_PASSWORD").expect("SKYBRIDGE_TEST_PASSWORD");

    let mut auth = AuthenticationService::new().expect("auth service");
    println!("supabase_configured={}", auth.is_supabase_configured());

    match auth.login_email(&email, &password).await {
        Ok(session) => {
            println!(
                "ok user_id={} nebula_id={}",
                session.user.user_id,
                session
                    .user
                    .nebula_id
                    .as_ref()
                    .map(|id| id.formatted.as_str())
                    .unwrap_or("")
            );
        }
        Err(err) => {
            eprintln!("err {err}");
            std::process::exit(1);
        }
    }
}
