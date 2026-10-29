use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

#[test]
fn cli_check_coverage_source_catalog_includes_every_cli_rust_source() {
    let source_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut source_paths = BTreeSet::new();
    collect_rust_source_paths(&source_root, &source_root, &mut source_paths)
        .expect("collect CLI Rust source paths");

    let catalog_paths = catalog_include_paths();
    let catalog_path_count = super::cli_check_coverage_source_paths().count();
    assert_eq!(
        catalog_path_count,
        catalog_paths.len(),
        "CLI source catalog must not contain duplicate include paths"
    );
    let missing_paths = source_paths
        .difference(&catalog_paths)
        .cloned()
        .collect::<Vec<_>>();
    let stale_paths = catalog_paths
        .difference(&source_paths)
        .cloned()
        .collect::<Vec<_>>();

    assert!(
        missing_paths.is_empty() && stale_paths.is_empty(),
        "CLI source catalog drift detected; missing={missing_paths:?} stale={stale_paths:?}"
    );
}

fn collect_rust_source_paths(
    root: &Path,
    directory: &Path,
    paths: &mut BTreeSet<String>,
) -> std::io::Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_rust_source_paths(root, &path, paths)?;
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            let relative = path
                .strip_prefix(root)
                .expect("source path should be inside source root");
            paths.insert(relative_path_string(relative));
        }
    }
    Ok(())
}

fn relative_path_string(path: &Path) -> String {
    path.components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

fn catalog_include_paths() -> BTreeSet<String> {
    super::cli_check_coverage_source_paths()
        .map(str::to_owned)
        .collect()
}
