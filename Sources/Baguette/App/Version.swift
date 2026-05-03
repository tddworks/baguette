// Single source of truth for the CLI version string. The release
// workflow rewrites this literal in CI before `swift build` (see
// `.github/workflows/release.yml` step "Inject release version") so
// shipped binaries report their actual tag. The value committed here
// is what local debug / Homebrew-from-source builds report.
let baguetteVersion = "0.1.61"
