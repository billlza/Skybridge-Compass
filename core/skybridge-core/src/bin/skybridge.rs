fn main() {
    let args = std::env::args().skip(1);
    let mut stdout = std::io::stdout();
    let mut stderr = std::io::stderr();
    let code = skybridge_core::cli::run(args, &mut stdout, &mut stderr);
    std::process::exit(code);
}
